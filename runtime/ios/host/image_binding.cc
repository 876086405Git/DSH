#include "image_binding.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <node.h>
#include <node_api.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

namespace {

// Releases a Core Foundation or Core Graphics object at the end of a scope.
template <typename T>
class Held {
 public:
  explicit Held(T value) : value_(value) {}
  ~Held() {
    if (value_ != nullptr) CFRelease(value_);
  }
  Held(const Held&) = delete;
  Held& operator=(const Held&) = delete;
  T get() const { return value_; }
  explicit operator bool() const { return value_ != nullptr; }

 private:
  T value_;
};

struct Job {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  napi_ref input = nullptr;
  const UInt8* bytes = nullptr;
  size_t length = 0;
  bool encode = false;
  // What to encode. A width or height of 0 wasn't asked for.
  int64_t width = 0;
  int64_t height = 0;
  bool orient = false;
  bool png = false;
  double quality = 0.85;
  std::vector<UInt8> output;
  int64_t outputWidth = 0;
  int64_t outputHeight = 0;
  const char* failure = nullptr;
};

CFMutableDictionaryRef NewDictionary() {
  return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
}

int64_t Integer(CFDictionaryRef properties, CFStringRef key) {
  auto number = static_cast<CFNumberRef>(CFDictionaryGetValue(properties, key));
  int64_t value = 0;
  if (number != nullptr) CFNumberGetValue(number, kCFNumberSInt64Type, &value);
  return value;
}

void Decode(CGImageSourceRef source, Job* job) {
  // A small copy made from the image itself still has ImageIO go through the image, without holding a
  // 48-megapixel photo's 180 MB in the same process as the engine.
  int longEdge = 1024;
  Held<CFNumberRef> edge(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &longEdge));
  Held<CFMutableDictionaryRef> options(NewDictionary());
  CFDictionarySetValue(options.get(), kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue);
  CFDictionarySetValue(options.get(), kCGImageSourceThumbnailMaxPixelSize, edge.get());
  CFDictionarySetValue(options.get(), kCGImageSourceShouldCacheImmediately, kCFBooleanTrue);
  Held<CGImageRef> image(CGImageSourceCreateThumbnailAtIndex(source, 0, options.get()));
  if (!image || CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) {
    job->failure = "The image doesn't decode.";
  }
}

void Encode(CGImageSourceRef source, Job* job) {
  Held<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
  if (!properties) {
    job->failure = "The image can't be read.";
    return;
  }
  const int64_t sourceWidth = Integer(properties.get(), kCGImagePropertyPixelWidth);
  const int64_t sourceHeight = Integer(properties.get(), kCGImagePropertyPixelHeight);
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    job->failure = "The image can't be read.";
    return;
  }
  const bool turned = job->orient && Integer(properties.get(), kCGImagePropertyOrientation) >= 5;
  const double wide = static_cast<double>(turned ? sourceHeight : sourceWidth);
  const double high = static_cast<double>(turned ? sourceWidth : sourceHeight);
  double scale = 1;
  if (job->width > 0) scale = std::min(scale, static_cast<double>(job->width) / wide);
  if (job->height > 0) scale = std::min(scale, static_cast<double>(job->height) / high);
  int64_t longEdge = std::max<int64_t>(1, std::llround(std::max(wide, high) * scale));

  // Scaling while decoding keeps a large photo's full pixels out of memory.
  Held<CFNumberRef> edge(CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &longEdge));
  Held<CFMutableDictionaryRef> options(NewDictionary());
  CFDictionarySetValue(options.get(), kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue);
  CFDictionarySetValue(options.get(), kCGImageSourceCreateThumbnailWithTransform,
                       job->orient ? kCFBooleanTrue : kCFBooleanFalse);
  CFDictionarySetValue(options.get(), kCGImageSourceThumbnailMaxPixelSize, edge.get());
  CFDictionarySetValue(options.get(), kCGImageSourceShouldCacheImmediately, kCFBooleanTrue);
  Held<CGImageRef> sized(CGImageSourceCreateThumbnailAtIndex(source, 0, options.get()));
  if (!sized) {
    job->failure = "The image can't be resized.";
    return;
  }

  // Drawing into an sRGB bitmap is what converts the colours.
  const size_t width = CGImageGetWidth(sized.get());
  const size_t height = CGImageGetHeight(sized.get());
  Held<CGColorSpaceRef> srgb(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
  const uint32_t alpha = static_cast<uint32_t>(job->png ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNoneSkipLast);
  const uint32_t layout = alpha | static_cast<uint32_t>(kCGBitmapByteOrder32Big);
  Held<CGContextRef> canvas(CGBitmapContextCreate(nullptr, width, height, 8, 0, srgb.get(), layout));
  if (!canvas) {
    job->failure = "There isn't memory to draw the image.";
    return;
  }
  const CGRect area = CGRectMake(0, 0, static_cast<CGFloat>(width), static_cast<CGFloat>(height));
  if (!job->png) {
    CGContextSetRGBFillColor(canvas.get(), 1, 1, 1, 1);
    CGContextFillRect(canvas.get(), area);
  }
  CGContextSetInterpolationQuality(canvas.get(), kCGInterpolationHigh);
  CGContextDrawImage(canvas.get(), area, sized.get());
  Held<CGImageRef> drawn(CGBitmapContextCreateImage(canvas.get()));
  if (!drawn) {
    job->failure = "There isn't memory to draw the image.";
    return;
  }

  Held<CFMutableDataRef> encoded(CFDataCreateMutable(kCFAllocatorDefault, 0));
  Held<CGImageDestinationRef> destination(CGImageDestinationCreateWithData(
      encoded.get(), job->png ? CFSTR("public.png") : CFSTR("public.jpeg"), 1, nullptr));
  if (!destination) {
    job->failure = "The image can't be encoded.";
    return;
  }
  Held<CFMutableDictionaryRef> settings(NewDictionary());
  Held<CFNumberRef> quality(CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &job->quality));
  if (!job->png) CFDictionarySetValue(settings.get(), kCGImageDestinationLossyCompressionQuality, quality.get());
  CGImageDestinationAddImage(destination.get(), drawn.get(), settings.get());
  if (!CGImageDestinationFinalize(destination.get())) {
    job->failure = "The image can't be encoded.";
    return;
  }
  const UInt8* bytes = CFDataGetBytePtr(encoded.get());
  job->output.assign(bytes, bytes + CFDataGetLength(encoded.get()));
  job->outputWidth = static_cast<int64_t>(width);
  job->outputHeight = static_cast<int64_t>(height);
}

void Execute(napi_env, void* raw) {
  auto* job = static_cast<Job*>(raw);
  Held<CFDataRef> input(CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, job->bytes,
                                                    static_cast<CFIndex>(job->length), kCFAllocatorNull));
  if (!input) {
    job->failure = "There isn't memory for the image.";
    return;
  }
  Held<CGImageSourceRef> source(CGImageSourceCreateWithData(input.get(), nullptr));
  if (!source || CGImageSourceGetStatus(source.get()) != kCGImageStatusComplete ||
      CGImageSourceGetCount(source.get()) < 1) {
    job->failure = "The image can't be read.";
    return;
  }
  if (job->encode) {
    Encode(source.get(), job);
  } else {
    Decode(source.get(), job);
  }
}

void Complete(napi_env env, napi_status status, void* raw) {
  std::unique_ptr<Job> job(static_cast<Job*>(raw));
  napi_delete_reference(env, job->input);
  napi_delete_async_work(env, job->work);
  napi_value value = nullptr;
  if (status != napi_ok || job->failure != nullptr) {
    napi_value code = nullptr;
    napi_value message = nullptr;
    napi_create_string_utf8(env, "ERR_IOS_IMAGE", NAPI_AUTO_LENGTH, &code);
    napi_create_string_utf8(env, job->failure != nullptr ? job->failure : "The image work was cancelled.",
                            NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, code, message, &value);
    napi_reject_deferred(env, job->deferred, value);
    return;
  }
  if (!job->encode) {
    napi_get_undefined(env, &value);
    napi_resolve_deferred(env, job->deferred, value);
    return;
  }
  napi_value data = nullptr;
  napi_value width = nullptr;
  napi_value height = nullptr;
  void* copy = nullptr;
  napi_create_buffer_copy(env, job->output.size(), job->output.data(), &copy, &data);
  napi_create_int64(env, job->outputWidth, &width);
  napi_create_int64(env, job->outputHeight, &height);
  napi_create_object(env, &value);
  napi_set_named_property(env, value, "data", data);
  napi_set_named_property(env, value, "width", width);
  napi_set_named_property(env, value, "height", height);
  napi_resolve_deferred(env, job->deferred, value);
}

// Holds on to the buffer until the work is done, off the JS thread.
napi_value Begin(napi_env env, napi_value buffer, std::unique_ptr<Job> job) {
  void* bytes = nullptr;
  bool isBuffer = false;
  if (napi_is_buffer(env, buffer, &isBuffer) != napi_ok || !isBuffer ||
      napi_get_buffer_info(env, buffer, &bytes, &job->length) != napi_ok || job->length == 0) {
    napi_throw_type_error(env, "ERR_IOS_IMAGE", "An image has to be a non-empty Buffer.");
    return nullptr;
  }
  job->bytes = static_cast<const UInt8*>(bytes);
  napi_value promise = nullptr;
  napi_value name = nullptr;
  if (napi_create_reference(env, buffer, 1, &job->input) != napi_ok ||
      napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
      napi_create_string_utf8(env, "dsh_ios_image", NAPI_AUTO_LENGTH, &name) != napi_ok ||
      napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) != napi_ok ||
      napi_queue_async_work(env, job->work) != napi_ok) {
    napi_throw_error(env, "ERR_IOS_IMAGE", "The image work didn't start.");
    return nullptr;
  }
  job.release();
  return promise;
}

napi_value DecodeCall(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value argument = nullptr;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1) {
    napi_throw_type_error(env, "ERR_IOS_IMAGE", "decode(image)");
    return nullptr;
  }
  return Begin(env, argument, std::make_unique<Job>());
}

// encode(image, width, height, orient, png, quality)
napi_value EncodeCall(napi_env env, napi_callback_info info) {
  size_t count = 6;
  napi_value arguments[6] = {};
  auto job = std::make_unique<Job>();
  job->encode = true;
  if (napi_get_cb_info(env, info, &count, arguments, nullptr, nullptr) != napi_ok || count != 6 ||
      napi_get_value_int64(env, arguments[1], &job->width) != napi_ok ||
      napi_get_value_int64(env, arguments[2], &job->height) != napi_ok ||
      napi_get_value_bool(env, arguments[3], &job->orient) != napi_ok ||
      napi_get_value_bool(env, arguments[4], &job->png) != napi_ok ||
      napi_get_value_double(env, arguments[5], &job->quality) != napi_ok) {
    napi_throw_type_error(env, "ERR_IOS_IMAGE", "encode(image, width, height, orient, png, quality)");
    return nullptr;
  }
  return Begin(env, arguments[0], std::move(job));
}

napi_value Initialize(napi_env env, napi_value exports) {
  napi_value decode = nullptr;
  napi_value encode = nullptr;
  if (napi_create_function(env, "decode", NAPI_AUTO_LENGTH, DecodeCall, nullptr, &decode) != napi_ok ||
      napi_create_function(env, "encode", NAPI_AUTO_LENGTH, EncodeCall, nullptr, &encode) != napi_ok ||
      napi_set_named_property(env, exports, "decode", decode) != napi_ok ||
      napi_set_named_property(env, exports, "encode", encode) != napi_ok) {
    return nullptr;
  }
  return exports;
}

napi_module module = {NAPI_MODULE_VERSION, node::ModuleFlags::kLinked,
  "runtime/ios/host/image_binding.cc", Initialize, "dsh_ios_image", nullptr, {nullptr, nullptr, nullptr, nullptr}};

}  // namespace

void RegisterImageBinding() { napi_module_register(&module); }
