// Keep the LoongArch binding adaptation in sync with the source-built library.
#include <cstdint>
#include <string_view>

#include "cppgc/garbage-collected.h"
#include "cppgc/member.h"
#include "v8-typed-array.h"
#include "v8-version-string.h"

namespace {
class BindingLayoutProbe : public cppgc::GarbageCollected<BindingLayoutProbe> {};

// Bazel currently builds cppgc without GN's caged-heap pointer compression.
static_assert(sizeof(cppgc::Member<BindingLayoutProbe>) == 8);
static_assert(sizeof(cppgc::WeakMember<BindingLayoutProbe>) == 8);
static_assert(V8_TYPED_ARRAY_MAX_SIZE_IN_HEAP == 64);
static_assert(std::string_view(V8_VERSION_STRING) == "15.2.124.1");

#ifdef V8_ENABLE_SANDBOX
constexpr uint64_t kExpectedMaxBytes = (uint64_t{1} << 35) - 1;
#else
constexpr uint64_t kExpectedMaxBytes = (uint64_t{1} << 53) - 1;
#endif
static_assert(v8::TypedArray::kMaxByteLength == kExpectedMaxBytes);

#define CHECK_TYPED_ARRAY_LIMIT(Name, Element) \
  static_assert(v8::Name::kMaxLength == kExpectedMaxBytes / sizeof(Element))
CHECK_TYPED_ARRAY_LIMIT(Uint8Array, uint8_t);
CHECK_TYPED_ARRAY_LIMIT(Uint8ClampedArray, uint8_t);
CHECK_TYPED_ARRAY_LIMIT(Int8Array, int8_t);
CHECK_TYPED_ARRAY_LIMIT(Uint16Array, uint16_t);
CHECK_TYPED_ARRAY_LIMIT(Int16Array, int16_t);
CHECK_TYPED_ARRAY_LIMIT(Uint32Array, uint32_t);
CHECK_TYPED_ARRAY_LIMIT(Int32Array, int32_t);
CHECK_TYPED_ARRAY_LIMIT(Float16Array, uint16_t);
CHECK_TYPED_ARRAY_LIMIT(Float32Array, float);
CHECK_TYPED_ARRAY_LIMIT(Float64Array, double);
CHECK_TYPED_ARRAY_LIMIT(BigInt64Array, int64_t);
CHECK_TYPED_ARRAY_LIMIT(BigUint64Array, uint64_t);
#undef CHECK_TYPED_ARRAY_LIMIT
}  // namespace
