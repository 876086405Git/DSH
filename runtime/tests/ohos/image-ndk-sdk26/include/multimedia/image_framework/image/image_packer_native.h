/*
 * Copyright (C) 2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * @addtogroup Image_NativeModule
 * @{
 *
 * @brief Provides APIs for access to the image interface.
 *
 * @since 12
 */
/**
 * @file image_packer_native.h
 *
 * @brief The file declares the APIs for image encoding.
 * 
 * @library libimage_packer.so
 * @kit ImageKit
 * @syscap SystemCapability.Multimedia.Image.ImagePacker
 * @since 12
 */

#ifndef INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_PACKER_NATIVE_H_
#define INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_PACKER_NATIVE_H_
#include "info/application_target_sdk_version.h"
#include <stdbool.h>

#include "image_common.h"
#include "image_source_native.h"
#include "pixelmap_native.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief The struct describes the image packer, which is used to perform operations related to an image packer.
 * 
 * @since 12
 */
struct OH_ImagePackerNative;
typedef struct OH_ImagePackerNative OH_ImagePackerNative;

/**
 * @brief OH_PackingOptions is an image encoding option struct encapsulated at the native layer. It cannot be
 * manipulated directly; instead, functions shall be called to create and release the struct, and operate on its
 * specific fields.
 * 
 * @since 12
 */
struct OH_PackingOptions;
typedef struct OH_PackingOptions OH_PackingOptions;

/**
 * @brief OH_PackingOptionsForSequence is an image sequence encoding option struct encapsulated at the native layer. It
 * cannot be manipulated directly; instead, functions shall be called to create and release the struct, and operate on
 * its specific fields.
 * 
 * @since 18
 */
struct OH_PackingOptionsForSequence;

/**
 * @brief OH_PackingOptionsForSequence is an image sequence encoding option struct encapsulated at the native layer. It
 * cannot be manipulated directly; instead, functions shall be called to create and release the struct, and operate on
 * its specific fields.
 * 
 * @since 18
 */
typedef struct OH_PackingOptionsForSequence OH_PackingOptionsForSequence;

/**
 * @brief Enumerates the dynamic range for encoding.
 * 
 * @since 12
 */
typedef enum {
    /**
     * Packing according to the content of the image.
     */
    IMAGE_PACKER_DYNAMIC_RANGE_AUTO = 0,
    /**
     * Packing to standard dynamic range.
     */
    IMAGE_PACKER_DYNAMIC_RANGE_SDR = 1,
} IMAGE_PACKER_DYNAMIC_RANGE;

/**
 * @brief Creates the pointer to an OH_PackingOptions struct.
 * 
 * @param options Double pointer to the OH_PackingOptions struct created.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_BAD_PARAMETER} options is nullptr.</li>
 *         </ul>
 * @release image_packer_native/OH_PackingOptions_Release {options}
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_Create(OH_PackingOptions **options)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the MIME type. **value.data** obtained through this API lacks the string terminator **\0**. Please
 * use it with caution.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param format Pointer to the MIME type. You can pass in a null pointer with the size set to zero. In this case,
 *     the system will allocate memory, but you must release the memory after use.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or format is nullptr.
 *     <br>{@link IMAGE_ALLOC_FAILED} allocate memory failed.
 *     <br>{@link IMAGE_COPY_FAILED} copy memory failed
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_GetMimeType(OH_PackingOptions *options,
    Image_MimeType *format)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the MIME type in the packing options. The output **format.data** ends with the string terminator **\0**.
 *
 * @param options Pointer to an OH_PackingOptions struct.
 * @param format Pointer to the MIME type.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_PACKER_INVALID_PARAMETER} if options or format is nullptr.
 * @since 19
 */
Image_ErrorCode OH_PackingOptions_GetMimeTypeWithNull(OH_PackingOptions *options,
    Image_MimeType *format)
    __attribute__((__availability__(ohos, introduced=19.0.0)));

/**
 * @brief Sets the MIME type.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param format Pointer to a MIME type string in the form "type/subtype".
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or format is nullptr.
 *     <br>{@link IMAGE_ALLOC_FAILED} allocate memory failed.
 *     <br>{@link IMAGE_COPY_FAILED} copy memory failed.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_SetMimeType(OH_PackingOptions *options,
    Image_MimeType *format)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the encoding quality.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param quality Pointer to the encoding quality.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or quality is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_GetQuality(OH_PackingOptions *options,
    uint32_t *quality)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the encoding quality.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param quality Encoding quality.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_SetQuality(OH_PackingOptions *options,
    uint32_t quality)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the **needsPackProperties** parameter in the OH_PackingOptions struct.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param needsPackProperties Whether to encode image property information (for example, Exif). The values include **true**
 * (yes) and **false** (no).
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or needsPackProperties is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_GetNeedsPackProperties(OH_PackingOptions *options,
    bool *needsPackProperties)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the **needsPackProperties** parameter in the OH_PackingOptions struct.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param needsPackProperties Whether to encode image property information (for example, Exif). The values include **true**
 * (yes) and **false** (no).
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_SetNeedsPackProperties(OH_PackingOptions *options,
    bool needsPackProperties)
    __attribute__((__availability__(ohos, introduced=12.0.0)));



/**
 * @brief Obtains the desired dynamic range during encoding.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param desiredDynamicRange Desired dynamic range. For details about the available options, see {@link IMAGE_PACKER_DYNAMIC_RANGE}
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredDynamicRange is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_GetDesiredDynamicRange(OH_PackingOptions *options, int32_t* desiredDynamicRange)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the desired dynamic range during encoding.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @param desiredDynamicRange Desired dynamic range. For details about the available options, see
 * {@link IMAGE_PACKER_DYNAMIC_RANGE}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_SetDesiredDynamicRange(OH_PackingOptions *options, int32_t desiredDynamicRange)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Releases the pointer to an OH_PackingOptions struct.
 * 
 * @param options Pointer to an OH_PackingOptions struct.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_PackingOptions_Release(OH_PackingOptions *options)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_PackingOptionsForSequence struct.
 * 
 * @param options Double pointer to OH_PackingOptionsForSequence.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_Create(OH_PackingOptionsForSequence **options)
__attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the number of frames for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param frameCount Number of frames.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_SetFrameCount(OH_PackingOptionsForSequence *options,
    uint32_t frameCount)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Obtains the number of frames for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param frameCount Pointer to the number of frames.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or frameCount is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_GetFrameCount(OH_PackingOptionsForSequence *options,
    uint32_t *frameCount)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the delay time array for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param delayTimeList Pointer to the delay time array.
 * @param delayTimeListLength Length of the delay time array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or delayTimeList is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_SetDelayTimeList(OH_PackingOptionsForSequence *options,
    int32_t *delayTimeList, size_t delayTimeListLength)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Obtains the delay time array for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param delayTimeList Pointer to the delay time array.
 * @param delayTimeListLength Length of the delay time array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or delayTimeList is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_GetDelayTimeList(OH_PackingOptionsForSequence *options,
    int32_t *delayTimeList, size_t delayTimeListLength)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the disposal type array for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param disposalTypes Pointer to an array that defines how each image frame transitions. If the array length is less
 *     than **frameCount**, the last value in the array will be used for the remaining frames. The values can be:
 *     **0**: No operation is required.
 *     **1**: Keeps the image unchanged.
 *     **2**: Restores the background color.
 *     **3**: Restores to the previous state.
 * @param disposalTypesLength Length of the disposal type array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or disposalTypes is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_SetDisposalTypes(OH_PackingOptionsForSequence *options,
    uint32_t *disposalTypes, size_t disposalTypesLength)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Obtains the disposal type array for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param disposalTypes Pointer to the disposal type array.
 * @param disposalTypesLength Length of the disposal type array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or disposalTypes is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_GetDisposalTypes(OH_PackingOptionsForSequence *options,
    uint32_t *disposalTypes, size_t disposalTypesLength)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the number of loops for image sequence encoding. The value range is [0, 65535], where **0** means an
 * infinite loop. If this field is not carried, loop playback is not performed.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence .
 * @param loopCount Number of loops.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_SetLoopCount(OH_PackingOptionsForSequence *options, uint32_t loopCount)
__attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Obtains the number of loops for image sequence encoding.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @param loopCount Pointer to the number of loops.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or loopCount is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_GetLoopCount(OH_PackingOptionsForSequence *options, uint32_t *loopCount)
__attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Releases the pointer to an OH_PackingOptionsForSequence struct.
 * 
 * @param options Pointer to OH_PackingOptionsForSequence.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 18
 */
Image_ErrorCode OH_PackingOptionsForSequence_Release(OH_PackingOptionsForSequence *options)
__attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Creates the pointer to an OH_ImagePackerNative struct.
 * 
 * @param imagePacker Double pointer to OH_ImagePackerNative.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_BAD_PARAMETER} imagePacker is nullptr.</li>
 *         </ul>
 * @release image_packer_native/OH_ImagePackerNative_Release {imagePacker}
 * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_Create(OH_ImagePackerNative **imagePacker)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Encodes an image source into data in a given format.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param imageSource Pointer to the image source to encode.
 * @param outData Pointer to the buffer used to store the output data.
 * @param size Pointer to the size of the buffer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}imagePacker is nullptr, or options is nullptr,
 *         or imageSource is nullptr, or outData is nullptr.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_PackToDataFromImageSource(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_ImageSourceNative *imageSource, uint8_t *outData, size_t *size)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Encodes a PixelMap into data in a given format.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param pixelmap Pointer to the PixelMap to encode.
 * @param outData Pointer to the buffer used to store the output data.
 * @param size Pointer to the size of the buffer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}imagePacker is nullptr, or options is nullptr,
 *         or pixelmap is nullptr, or outData is nullptr.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_PackToDataFromPixelmap(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_PixelmapNative *pixelmap, uint8_t *outData, size_t *size)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Encodes a picture into data in a given format.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param picture Pointer to the picture to encode.
 * @param outData Pointer to the buffer used to store the output data.
 * @param size Pointer to the size of the buffer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} imagePacker is nullptr, or picture is nullptr, or outData is nullptr,
 *         or size is invalid.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 13
 */
Image_ErrorCode OH_ImagePackerNative_PackToDataFromPicture(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_PictureNative *picture, uint8_t *outData, size_t *size)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Encodes a PixelMap sequence into data.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an {@link OH_PackingOptionsForSequence} struct.
 * @param pixelmapSequence Double pointer to the PixelMap sequence to encode.
 * @param sequenceLength Length of the PixelMap sequence.
 * @param outData Pointer to the buffer used to store the output data.
 * @param outDataSize Pointer to the size of the buffer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} one of the pointer type parameters is nullptr, or size/length is invalid
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 18
 */
Image_ErrorCode OH_ImagePackerNative_PackToDataFromPixelmapSequence(OH_ImagePackerNative *imagePacker,
    OH_PackingOptionsForSequence *options, OH_PixelmapNative **pixelmapSequence,
    size_t sequenceLength, uint8_t *outData, size_t *outDataSize)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Encodes an image source into a file.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param imageSource Pointer to the image source to encode.
 * @param fd File descriptor, which is writable.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}imagePacker is nullptr, or options is nullptr,
 *         or imageSource is nullptr, or fd is invalid.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_PackToFileFromImageSource(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_ImageSourceNative *imageSource, int32_t fd)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Encodes a PixelMap into a file.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param pixelmap Pointer to the PixelMap to encode.
 * @param fd File descriptor, which is writable.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}imagePacker is nullptr, or options is nullptr,
 *         or pixelmap is nullptr, or fd is invalid.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
  * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_PackToFileFromPixelmap(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_PixelmapNative *pixelmap, int32_t fd)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Encodes a picture into a file.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an OH_PackingOptions struct.
 * @param picture Pointer to the picture to encode.
 * @param fd File descriptor, which is writable.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} imagePacker is nullptr, or picture is nullptr, or fd is invalid.
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 13
 */
Image_ErrorCode OH_ImagePackerNative_PackToFileFromPicture(OH_ImagePackerNative *imagePacker,
    OH_PackingOptions *options, OH_PictureNative *picture, int32_t fd)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Encodes a PixelMap sequence into a file.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @param options Pointer to an {@link OH_PackingOptionsForSequence} struct.
 * @param pixelmapSequence Double pointer to the PixelMap sequence to encode.
 * @param sequenceLength Length of the PixelMap sequence.
 * @param fd File descriptor, which is writable.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} one of the pointer type parameters is nullptr, or length is invalid
 *     <br>{@link IMAGE_ENCODE_FAILED} encode failed.
 * @since 18
 */
Image_ErrorCode OH_ImagePackerNative_PackToFileFromPixelmapSequence(OH_ImagePackerNative *imagePacker,
    OH_PackingOptionsForSequence *options, OH_PixelmapNative **pixelmapSequence, size_t sequenceLength, int32_t fd)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Releases the pointer to an OH_ImagePackerNative struct.
 * 
 * @param imagePacker Pointer to OH_ImagePackerNative.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} imagePacker is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImagePackerNative_Release(OH_ImagePackerNative *imagePacker)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the supported image formats that can be encoded.
 * 
 * @param supportedFormats Double pointer to the supported image formats.
 * @param length Pointer to the size of the array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_PACKER_INVALID_PARAMETER} if <b>supportedFormats</b> or <b>length</b> is empty.
 * @since 20
 */
Image_ErrorCode OH_ImagePackerNative_GetSupportedFormats(Image_MimeType** supportedFormats, size_t* length)
__attribute__((__availability__(ohos, introduced=20.0.0)));

#ifdef __cplusplus
};
#endif
/** @} */
#endif // INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_PACKER_NATIVE_H_
