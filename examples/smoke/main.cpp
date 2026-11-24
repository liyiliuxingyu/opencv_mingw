#include <opencv2/core.hpp>
#include <opencv2/core/utility.hpp>
#include <opencv2/core/version.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/videoio.hpp>
#include <opencv2/videoio/registry.hpp>

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <numeric>
#include <regex>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
void require(bool condition, const std::string& message)
{
    if (!condition) {
        throw std::runtime_error(message);
    }
}

void write_text(const fs::path& path, const std::string& value)
{
    std::ofstream stream(path, std::ios::binary);
    require(stream.is_open(), "Cannot create diagnostic file: " + path.string());
    stream << value;
    require(stream.good(), "Cannot write diagnostic file: " + path.string());
}

void check_images(const fs::path& directory)
{
    cv::Mat source(64, 96, CV_8UC3, cv::Scalar(0, 0, 255));
    source(cv::Rect(48, 0, 48, 64)).setTo(cv::Scalar(255, 0, 0));

    cv::Mat gray;
    cv::cvtColor(source, gray, cv::COLOR_BGR2GRAY);
    require(gray.type() == CV_8UC1 && gray.size() == source.size(),
            "cvtColor returned an unexpected image type or size.");
    require(gray.at<unsigned char>(20, 20) == 76,
            "Known red pixel did not convert to grayscale value 76.");
    require(gray.at<unsigned char>(20, 70) == 29,
            "Known blue pixel did not convert to grayscale value 29.");

    const auto image_file = directory / "roundtrip.png";
    require(cv::imwrite(image_file.string(), source), "PNG file encoding failed.");
    const cv::Mat decoded = cv::imread(image_file.string(), cv::IMREAD_COLOR);
    require(!decoded.empty() && decoded.type() == source.type()
                && decoded.size() == source.size(),
            "PNG file decoding returned an empty or incompatible image.");
    require(cv::norm(source, decoded, cv::NORM_INF) == 0.0,
            "PNG lossless round trip changed pixel values.");

    std::vector<unsigned char> encoded;
    require(cv::imencode(".png", source, encoded), "PNG memory encoding failed.");
    const cv::Mat memory_decoded = cv::imdecode(encoded, cv::IMREAD_COLOR);
    require(!memory_decoded.empty()
                && cv::norm(source, memory_decoded, cv::NORM_INF) == 0.0,
            "PNG memory round trip changed pixel values.");
}

void check_parallel_operation()
{
    constexpr int count = 4096;
    std::vector<std::int64_t> values(count, -1);
    cv::parallel_for_(cv::Range(0, count), [&](const cv::Range& range) {
        for (int i = range.start; i < range.end; ++i) {
            values[i] = static_cast<std::int64_t>(i) * i;
        }
    });
    const std::int64_t sum = std::accumulate(values.begin(), values.end(), std::int64_t{0});
    const std::int64_t expected = static_cast<std::int64_t>(count - 1) * count * (2 * count - 1) / 6;
    require(sum == expected, "parallel_for_ produced an incorrect result.");
}

void check_ffmpeg(const fs::path& directory)
{
    const auto video_file = directory / "ffmpeg-roundtrip.avi";
    const cv::Size size(96, 64);
    constexpr int frame_count = 8;
    cv::VideoWriter writer(video_file.string(), cv::CAP_FFMPEG,
                           cv::VideoWriter::fourcc('M', 'J', 'P', 'G'), 10.0, size, true);
    require(writer.isOpened(), "FFmpeg could not open an MJPEG AVI writer.");
    require(writer.getBackendName() == "FFMPEG", "The video writer used an unexpected backend.");
    for (int i = 0; i < frame_count; ++i) {
        writer.write(cv::Mat(size, CV_8UC3, cv::Scalar(20 * i, 255 - 20 * i, 80)));
    }
    writer.release();

    cv::VideoCapture capture(video_file.string(), cv::CAP_FFMPEG);
    require(capture.isOpened(), "FFmpeg could not reopen the generated AVI file.");
    require(capture.getBackendName() == "FFMPEG", "The video reader used an unexpected backend.");
    int frames_read = 0;
    cv::Mat frame;
    while (capture.read(frame)) {
        require(frame.size() == size && frame.type() == CV_8UC3,
                "FFmpeg decoded an unexpected video frame.");
        ++frames_read;
    }
    require(frames_read == frame_count, "FFmpeg video round trip lost or added frames.");
}
} // namespace

int main(int argc, char** argv)
{
    try {
        require(argc >= 2, "Usage: opencv_mingw_smoke OUTPUT_DIR [--expected-version VERSION] [--expected-configuration Release|Debug] [--require-ffmpeg] [--require-openmp]");
        const fs::path output_directory(argv[1]);
        bool require_ffmpeg = false;
        bool require_openmp = false;
        std::string expected_version;
        std::string expected_configuration = OPENCV_SMOKE_CONFIGURATION;
        for (int i = 2; i < argc; ++i) {
            const std::string option(argv[i]);
            if (option == "--require-ffmpeg") {
                require_ffmpeg = true;
            } else if (option == "--require-openmp") {
                require_openmp = true;
            } else if (option == "--expected-version") {
                require(i + 1 < argc, "--expected-version requires a version.");
                expected_version = argv[++i];
            } else if (option == "--expected-configuration") {
                require(i + 1 < argc, "--expected-configuration requires Release or Debug.");
                expected_configuration = argv[++i];
                require(expected_configuration == "Release" || expected_configuration == "Debug",
                        "The expected configuration must be Release or Debug.");
            } else {
                throw std::runtime_error("Unknown option: " + option);
            }
        }
        fs::create_directories(output_directory);

        const std::string runtime_version = cv::getVersionString();
        const std::string build_information = cv::getBuildInformation();
        write_text(output_directory / "opencv-build-info.txt", build_information);
        write_text(output_directory / "opencv-version.txt", runtime_version + "\n");
        std::cout << "Header version: " << CV_VERSION << '\n'
                  << "Runtime version: " << runtime_version << '\n';
        require(runtime_version == CV_VERSION,
                "The loaded OpenCV DLL version does not match the compiled headers.");
        require(expected_version.empty() || runtime_version == expected_version,
                "The loaded OpenCV DLL version does not match build-info.json.");
        require(cv::getVersionMajor() == CV_VERSION_MAJOR
                    && cv::getVersionMinor() == CV_VERSION_MINOR
                    && cv::getVersionRevision() == CV_VERSION_REVISION,
                "Numeric OpenCV runtime version does not match the headers.");
        const std::regex configuration("Configuration:[ \\t]*" + expected_configuration + "[ \\t]*[\\r\\n]");
        require(std::regex_search(build_information, configuration),
                "The loaded OpenCV DLL configuration does not match the selected SDK configuration.");
        std::cout << "PASS: OpenCV runtime configuration " << expected_configuration << '\n';

        if (require_openmp) {
            const std::regex backend("Parallel framework:[ \\t]*OpenMP", std::regex::icase);
            require(std::regex_search(build_information, backend),
                    "The package was expected to use OpenMP, but the DLL reports a different parallel framework.");
        }
        check_images(output_directory);
        std::cout << "PASS: known-pixel cvtColor and lossless PNG file/memory round trips\n";
        check_parallel_operation();
        std::cout << "PASS: parallel_for_ calculation; reported thread count=" << cv::getNumThreads() << '\n';

        const bool ffmpeg_available = cv::videoio_registry::hasBackend(cv::CAP_FFMPEG);
        std::cout << "FFmpeg backend available: " << (ffmpeg_available ? "YES" : "NO") << '\n';
        require(!require_ffmpeg || ffmpeg_available,
                "The package was expected to include a usable FFmpeg backend.");
        if (ffmpeg_available) {
            check_ffmpeg(output_directory);
            std::cout << "PASS: FFmpeg MJPEG AVI encode/decode, eight frames\n";
        } else {
            std::cout << "SKIP: FFmpeg round trip (backend unavailable and not required)\n";
        }
        std::cout << "PASS: OpenCV SDK smoke test\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
