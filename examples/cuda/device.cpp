#include <opencv2/core.hpp>
#include <opencv2/core/cuda.hpp>
#include <opencv2/cudaarithm.hpp>
#include <opencv2/cudaimgproc.hpp>
#include <opencv2/imgproc.hpp>
#include <fstream>
#include <iostream>
#include <regex>
#include <stdexcept>
#include <string>

int main(int argc, char** argv) {
    try {
        if (argc < 2) throw std::runtime_error("Usage: opencv_cuda_device report.json [--require-gpu]");
        bool requireGPU = argc > 2 && std::string(argv[2]) == "--require-gpu";
        const std::string build = cv::getBuildInformation();
        if (!std::regex_search(build, std::regex("NVIDIA CUDA:[ \\t]+YES")))
            throw std::runtime_error("This OpenCV binary was not built with CUDA.");
        if (!std::regex_search(build, std::regex("cuDNN:[ \\t]+YES")))
            throw std::runtime_error("This OpenCV binary was not built with cuDNN.");
        int count = cv::cuda::getCudaEnabledDeviceCount();
        bool tested = false;
        if (count > 0) {
            cv::cuda::setDevice(0);
            cv::Mat input(32, 48, CV_8UC3, cv::Scalar(10, 100, 200));
            cv::Mat expected, result;
            cv::cvtColor(input, expected, cv::COLOR_BGR2GRAY);
            cv::cuda::GpuMat gpu, gray;
            gpu.upload(input);
            cv::cuda::cvtColor(gpu, gray, cv::COLOR_BGR2GRAY);
            gray.download(result);
            if (cv::norm(result, expected, cv::NORM_INF) > 1.0)
                throw std::runtime_error("CUDA color conversion disagrees with CPU reference.");
            cv::Mat addInput(16, 16, CV_32F, cv::Scalar(2.0f));
            cv::cuda::GpuMat a, sum;
            a.upload(addInput);
            cv::cuda::add(a, a, sum);
            sum.download(result);
            if (cv::norm(result, cv::Mat(16, 16, CV_32F, cv::Scalar(4.0f)), cv::NORM_INF) != 0)
                throw std::runtime_error("CUDA addition produced an incorrect result.");
            tested = true;
        }
        std::ofstream out(argv[1]);
        if (!out) throw std::runtime_error("Cannot write the GPU verification report.");
        out << "{\"cuda_compiled\":true,\"cudnn_compiled\":true,\"device_count\":" << count
            << ",\"gpu_execution\":\"" << (tested ? "passed" : "not-tested-no-compatible-device") << "\"}\n";
        std::cout << (tested ? "PASS: CUDA GPU operations executed" : "NOT TESTED: no compatible NVIDIA GPU/driver on this runner") << '\n';
        return requireGPU && !tested ? 2 : 0;
    } catch (const std::exception& e) {
        std::cerr << "CUDA check failed: " << e.what() << '\n';
        return 1;
    }
}
