cmake_minimum_required(VERSION 3.20)
project(OpenCVMinGWSmoke LANGUAGES CXX)

if(NOT WIN32 OR NOT MINGW)
  message(FATAL_ERROR "This example validates the Windows MinGW SDK. Select its bundled g++.exe.")
endif()
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(FATAL_ERROR "This SDK requires an x86-64 MinGW compiler (64-bit pointers).")
endif()

find_package(OpenCV CONFIG REQUIRED COMPONENTS core imgproc imgcodecs videoio)

add_executable(opencv_mingw_smoke main.cpp)
target_compile_features(opencv_mingw_smoke PRIVATE cxx_std_17)
set_target_properties(opencv_mingw_smoke PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(opencv_mingw_smoke PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(opencv_mingw_smoke PRIVATE ${OpenCV_LIBS})

enable_testing()
add_test(NAME opencv-sdk-smoke
  COMMAND opencv_mingw_smoke "${CMAKE_CURRENT_BINARY_DIR}/test-output")
set_tests_properties(opencv-sdk-smoke PROPERTIES TIMEOUT 120)
