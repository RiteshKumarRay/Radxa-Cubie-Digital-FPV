#include <iostream>
#include <vector>
#include <cmath>
#include <chrono>
#include <cstring>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#include <opencv2/core.hpp>
#include <opencv2/dnn.hpp>

using namespace std;

// ── NPU C-API Declarations ───────────────────────────────────────────────────
extern "C" {
    void  awnn_init();
    void  awnn_uninit();
    void* awnn_create(const char* model_path);
    void  awnn_destroy(void* ctx);
    void  awnn_set_input_buffers(void* ctx, void** buffers);
    void  awnn_run(void* ctx);
    float** awnn_get_output_buffers(void* ctx);
    unsigned int awnn_get_output_count(void* ctx);
    unsigned int awnn_get_output_elements(void* ctx, int index);
}

// ── Constants & Geometry ─────────────────────────────────────────────────────
// Landscape: 640 pixels Wide x 384 pixels Tall (16:9)
constexpr int FEED_W = 640;
constexpr int FEED_H = 360;
constexpr int FEED_BYTES = FEED_W * FEED_H * 3;

constexpr int MODEL_W = 640;
constexpr int MODEL_H = 384;
constexpr int CHW_SIZE = 3 * MODEL_H * MODEL_W;

constexpr int PAD_TOP = 12;  // 12 + 360 + 12 = 384

constexpr int PERSON_CLS = 0;
constexpr float CONF_THRESH = 0.48f;
// Early rejection threshold on raw logit: ln(0.48 / 0.52) ~ -0.08f
constexpr float EARLY_LOGIT_THRESH = -0.08f;
constexpr float IOU_THRESH = 0.40f;

// Strides: 8, 16, 32
// Feature map shapes for (384, 640):
// Stride 8:  H=48, W=80  (3840 cells)
// Stride 16: H=24, W=40  (960 cells)
// Stride 32: H=12, W=20  (240 cells)
struct HeadConfig {
    int stride;
    int gh;
    int gw;
};

const HeadConfig HEADS[3] = {
    {8,  48, 80},
    {16, 24, 40},
    {32, 12, 20}
};

inline float sigmoid_fast(float x) {
    return 1.0f / (1.0f + std::exp(std::max(std::min(-x, 88.0f), -88.0f)));
}

// DFL integral expectation: dist = sum(i * softmax(logits[i])) for i in 0..15
inline float dfl_1d(const float* logits) {
    float max_v = logits[0];
    for (int i = 1; i < 16; ++i) {
        if (logits[i] > max_v) max_v = logits[i];
    }
    float sum = 0.0f;
    float exp_v[16];
    for (int i = 0; i < 16; ++i) {
        exp_v[i] = std::exp(logits[i] - max_v);
        sum += exp_v[i];
    }
    float dist = 0.0f;
    float inv_sum = 1.0f / sum;
    for (int i = 0; i < 16; ++i) {
        dist += i * (exp_v[i] * inv_sum);
    }
    return dist;
}

struct BBox {
    float x1, y1, x2, y2;
    float score;
};

// Full read helper for stdin stream
bool read_all(int fd, uint8_t* buf, size_t count) {
    size_t total = 0;
    while (total < count) {
        ssize_t n = read(fd, buf + total, count - total);
        if (n <= 0) return false;
        total += n;
    }
    return true;
}

int main(int argc, char** argv) {
    const char* model_path = "/home/radxa/npu/yolov8n_384x640_a733.nb";
    if (access(model_path, F_OK) != 0) {
        model_path = "/home/radxa/npu/yolov8n_384x640_t527.nb";
    }
    if (argc > 1) model_path = argv[1];

    std::cout << "[NPU C++] Initializing VIP9000 with: " << model_path << std::endl;
    awnn_init();
    void* ctx = awnn_create(model_path);
    if (!ctx) {
        std::cerr << "[-] Failed to create NPU context!" << std::endl;
        return 1;
    }

    int n_out = awnn_get_output_count(ctx);
    std::cout << "[+] VIP9000 Ready — " << n_out << " output heads" << std::endl;

    // UDP Socket for WFB-ng Port 2 (UDP 127.0.0.1:5002)
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in target_addr{};
    target_addr.sin_family = AF_INET;
    target_addr.sin_port = htons(5002);
    inet_pton(AF_INET, "127.0.0.1", &target_addr.sin_addr);

    // Pre-allocated static buffers
    // Model expects interleaved HWC uint8 RGB [1, 384, 640, 3] from Pegasus IMAGE_RGB preproc
    vector<uint8_t> feed_raw(FEED_BYTES);
    vector<uint8_t> hwc_buf(MODEL_H * MODEL_W * 3, 114); // Gray padding
    void* in_ptrs[1] = { hwc_buf.data() };

    uint32_t seq = 0;
    int frame_cnt = 0;
    auto t_fps = std::chrono::steady_clock::now();
    float cur_fps = 0.0f;
    auto t_last_send = std::chrono::steady_clock::now();

    std::cout << "[+] C++ YOLOv8n Tracker listening on stdin (640x360 RGB)..." << std::endl;

    while (true) {
        if (!read_all(0, feed_raw.data(), FEED_BYTES)) {
            std::cout << "[!] stdin EOF — exiting." << std::endl;
            break;
        }

        // Direct copy of 640x360 RGB frame into 640x384 buffer with 12px letterbox padding
        // Hardware pre-processing node in NBG consumes packed interleaved RGB (HWC) uint8
        memcpy(hwc_buf.data() + (PAD_TOP * MODEL_W * 3), feed_raw.data(), FEED_BYTES);

        // NPU Inference
        auto t0 = std::chrono::steady_clock::now();
        awnn_set_input_buffers(ctx, in_ptrs);
        awnn_run(ctx);
        float** outputs = awnn_get_output_buffers(ctx);
        auto t1 = std::chrono::steady_clock::now();
        int inf_ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();

        // Decode 6 Heads
        vector<cv::Rect2d> cand_boxes;
        vector<float> cand_scores;

        for (int h = 0; h < 3; ++h) {
            int stride = HEADS[h].stride;
            int gh = HEADS[h].gh;
            int gw = HEADS[h].gw;

            // Box head: (64, gh, gw), Class head: (80, gh, gw)
            const float* box_head = outputs[h * 2];
            const float* cls_head = outputs[h * 2 + 1];

            // Person is channel 0 of cls_head
            const float* person_logits = cls_head; // channel 0 starts at offset 0
            int grid_area = gh * gw;

            for (int gy = 0; gy < gh; ++gy) {
                for (int gx = 0; gx < gw; ++gx) {
                    int cell_idx = gy * gw + gx;
                    float logit = person_logits[cell_idx];

                    // Early skip background
                    if (logit < EARLY_LOGIT_THRESH) continue;

                    // Verify that Person (class 0) is the dominant class at this anchor
                    // Eliminates false positives from chairs, walls, bags, clothing
                    bool is_person_max = true;
                    for (int k = 1; k < 80; ++k) {
                        if (cls_head[k * grid_area + cell_idx] >= logit) {
                            is_person_max = false;
                            break;
                        }
                    }
                    if (!is_person_max) continue;

                    float score = sigmoid_fast(logit);
                    if (score < CONF_THRESH) continue;

                    // Extract 4 x 16 logits
                    // box_head shape is (64, gh, gw) -> channel c at c * grid_area + cell_idx
                    float dist_logits[4][16];
                    for (int c = 0; c < 64; ++c) {
                        dist_logits[c / 16][c % 16] = box_head[c * grid_area + cell_idx];
                    }

                    float l = dfl_1d(dist_logits[0]);
                    float t = dfl_1d(dist_logits[1]);
                    float r = dfl_1d(dist_logits[2]);
                    float b = dfl_1d(dist_logits[3]);

                    float cx = (gx + 0.5f);
                    float cy = (gy + 0.5f);

                    float x1 = (cx - l) * stride;
                    float y1 = (cy - t) * stride;
                    float x2 = (cx + r) * stride;
                    float y2 = (cy + b) * stride;

                    // Normalize to 0..1 relative to 640x360 feed (undo 12px padding)
                    float nx1 = std::max(0.0f, std::min(1.0f, x1 / MODEL_W));
                    float ny1 = std::max(0.0f, std::min(1.0f, (y1 - PAD_TOP) / FEED_H));
                    float nx2 = std::max(0.0f, std::min(1.0f, x2 / MODEL_W));
                    float ny2 = std::max(0.0f, std::min(1.0f, (y2 - PAD_TOP) / FEED_H));

                    float nw = nx2 - nx1;
                    float nh = ny2 - ny1;
                    if (nw > 0.008f && nh > 0.008f) {
                        cand_boxes.emplace_back(nx1, ny1, nw, nh);
                        cand_scores.push_back(score);
                    }
                }
            }
        }

        // OpenCV NMS
        vector<int> indices;
        if (!cand_boxes.empty()) {
            cv::dnn::NMSBoxes(cand_boxes, cand_scores, CONF_THRESH, IOU_THRESH, indices);
        }

        // FPS calculation
        frame_cnt++;
        auto now = std::chrono::steady_clock::now();
        float elapsed = std::chrono::duration<float>(now - t_fps).count();
        if (elapsed >= 2.0f) {
            cur_fps = std::round((frame_cnt / elapsed) * 10.0f) / 10.0f;
            frame_cnt = 0;
            t_fps = now;
            std::cout << "[NPU C++] " << cur_fps << " fps | " << inf_ms << "ms | " 
                      << indices.size() << " person(s)" << std::endl;
        }

        // Send UDP JSON (Port 2) up to 30 Hz
        float send_elapsed = std::chrono::duration<float>(now - t_last_send).count();
        if (send_elapsed >= 0.033f) {
            seq++;
            t_last_send = now;

            // Build compact JSON
            size_t max_dets = std::min(indices.size(), (size_t)6);
            char buf[1024];
            int len = snprintf(buf, sizeof(buf), "{\"s\":%u,\"f\":%.1f,\"m\":%d,\"p\":%zu,\"d\":[",
                               seq, cur_fps, inf_ms, max_dets);

            for (size_t i = 0; i < max_dets; ++i) {
                int idx = indices[i];
                const auto& b = cand_boxes[idx];
                float score = cand_scores[idx];
                len += snprintf(buf + len, sizeof(buf) - len,
                                "%s{\"b\":[%.4f,%.4f,%.4f,%.4f],\"c\":%.3f}",
                                (i > 0 ? "," : ""),
                                b.x, b.y, b.x + b.width, b.y + b.height, score);
            }
            len += snprintf(buf + len, sizeof(buf) - len, "]}");

            sendto(sock, buf, len, 0, (sockaddr*)&target_addr, sizeof(target_addr));
        }
    }

    close(sock);
    awnn_destroy(ctx);
    awnn_uninit();
    return 0;
}
