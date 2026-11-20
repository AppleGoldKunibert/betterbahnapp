// The Swift SDK for Android's runtime (libswiftCore's Metadata.cpp, Concurrency) was built against a newer libc++
// than any NDK ships: it calls std::__hash_memory, which libc++ only exports from LLVM 21 on. NDK r27-r29's
// libc++_shared.so doesn't have it, so Android refused to load libBetterBahnKit.so. This is libc++'s own
// definition (src/functional.cpp), built from the NDK's headers; build.sh checks that no such gap is left.
#if defined(__ANDROID__)
#include <cstddef>
#include <functional>

namespace std {
inline namespace __ndk1 {
__attribute__((visibility("default"))) size_t __hash_memory(const void* ptr, size_t size) noexcept {
    return __murmur2_or_cityhash<size_t>()(ptr, size);
}
} // namespace __ndk1
} // namespace std
#endif
