#include "file_access.h"

#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

namespace fs = std::filesystem;
void Check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::string Read(int fd) {
  char data[128]; const auto count = read(fd, data, sizeof(data));
  Check(count >= 0, "read failed"); return std::string(data, static_cast<size_t>(count));
}
void Reject(const std::string& root, const std::string& path) {
  try { const int fd = dsh::OpenUserFile(root, path); close(fd); }
  catch (const std::system_error&) { return; }
  throw std::runtime_error("path unexpectedly accepted");
}
size_t Fds() { return static_cast<size_t>(std::distance(fs::directory_iterator("/proc/self/fd"), fs::directory_iterator())); }

int main(int argc, char** argv) {
  try {
    Check(argc == 2, "provide new test directory");
    const fs::path base = argv[1]; Check(!fs::exists(base), "test directory must be fresh");
    const fs::path root = base / "workspace", outside = base / "private";
    fs::create_directories(root / "child"); fs::create_directories(outside);
    std::ofstream(root / "child" / "file.txt") << "inside";
    std::ofstream(outside / "file.txt") << "outside-secret";
    std::ofstream(root / "中文 空格\".txt") << "中文内容";
    const int unicode = dsh::OpenUserFile(root, "中文 空格\".txt");
    Check(Read(unicode) == "中文内容", "unicode bytes changed"); close(unicode);
    const size_t initial = Fds();
    for (const auto& name : std::vector<std::string>{"../private/file.txt", "/file.txt", "child/../child/file.txt", "child/./file.txt", "child//file.txt", "child/", "", std::string("child/file.txt\0x", 16)}) Reject(root, name);
    Reject("/", "etc/passwd"); Reject(root.string() + "/", "child/file.txt");
    fs::create_symlink(outside / "file.txt", root / "link.txt");
    fs::create_directory_symlink(outside, root / "directory-link");
    Reject(root, "link.txt"); Reject(root, "directory-link/file.txt"); Reject(root, "child");
    fs::create_directory_symlink(root, base / "root-link"); Reject(base / "root-link", "child/file.txt");
    Check(mkfifo((root / "pipe").c_str(), 0600) == 0, "mkfifo failed"); Reject(root, "pipe");
    const int held = dsh::OpenUserFile(root, "child/file.txt");
    fs::rename(root / "child" / "file.txt", root / "child" / "original.txt");
    fs::create_symlink(outside / "file.txt", root / "child" / "file.txt");
    Check(Read(held) == "inside", "opened descriptor followed path replacement"); close(held);
    fs::remove(root / "child" / "file.txt"); fs::rename(root / "child" / "original.txt", root / "child" / "file.txt");
    std::atomic<bool> ready{false}; size_t accepted = 0, rejected = 0;
    std::thread swap([&] {
      ready = true;
      for (int i = 0; i < 3000; ++i) {
        fs::rename(root / "child", root / "held");
        fs::create_directory_symlink(outside, root / "child");
        fs::remove(root / "child"); fs::rename(root / "held", root / "child");
      }
    });
    while (!ready.load()) std::this_thread::yield();
    bool escaped = false;
    for (int i = 0; i < 10000; ++i) {
      try {
        const int fd = dsh::OpenUserFile(root, "child/file.txt");
        escaped = escaped || Read(fd) != "inside"; close(fd); ++accepted;
      } catch (const std::system_error&) { ++rejected; }
    }
    swap.join(); Check(!escaped, "parent replacement escaped root");
    for (int i = 0; i < 1000; ++i) { const int fd = dsh::OpenUserFile(root, "child/file.txt"); close(fd); Reject(root, "link.txt"); }
    Check(Fds() == initial, "file descriptor leak");
    std::cout << "{\"status\":\"PASS\",\"raceAttempts\":10000,\"accepted\":" << accepted << ",\"rejected\":" << rejected << ",\"fdBefore\":" << initial << ",\"fdAfter\":" << Fds() << "}\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
