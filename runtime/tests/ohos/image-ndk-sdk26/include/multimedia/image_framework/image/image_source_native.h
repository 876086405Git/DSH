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
 * @file image_source_native.h
 *
 * @brief The file declares the APIs for image decoding.
 *
 * @library libimage_source.so
 * @kit ImageKit
 * @syscap SystemCapability.Multimedia.Image.ImageSource
 * @since 12
 */

#ifndef INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_SOURCE_NATIVE_H_
#define INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_SOURCE_NATIVE_H_
#include "info/application_target_sdk_version.h"
#include <stdbool.h>
#include "image_common.h"

#include "pixelmap_native.h"
#include "picture_native.h"
#include "rawfile/raw_file.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief The struct describes the image source, which is encapsulated at the native layer and is used to create image
 * data. The struct cannot be directly operated. Instead, functions must be called to create and release the struct and
 * operate the fields in the struct.
 * 
 * @since 12
 */
struct OH_ImageSourceNative;
typedef struct OH_ImageSourceNative OH_ImageSourceNative;

/**
 * @brief The OH_ImageSource_Info struct describes the image source information encapsulated at the native layer. The
 * struct cannot be directly operated. Instead, functions must be called to create and release the struct and operate
 * the fields in the struct.
 * 
 * @since 12
 */
struct OH_ImageSource_Info;
typedef struct OH_ImageSource_Info OH_ImageSource_Info;

/**
 * @brief The struct describes the decoding options for pictures. It is obtained by calling
 * {@link OH_DecodingOptionsForPicture_Create}.
 * 
 * @since 13
 */
struct OH_DecodingOptionsForPicture;

/**
 * @brief The struct describes the decoding options for pictures. It is obtained by calling
 * {@link OH_DecodingOptionsForPicture_Create}.
 *
 * @since 13
 */
typedef struct OH_DecodingOptionsForPicture OH_DecodingOptionsForPicture;

/**
 * @brief Enumerates the desired dynamic range for decoding.
 * 
 * @since 12
 */
typedef enum {
    /**
     * Dynamic range depends on the image.
     */
    IMAGE_DYNAMIC_RANGE_AUTO = 0,
    /**
     * Standard dynamic range.
     */
    IMAGE_DYNAMIC_RANGE_SDR = 1,
    /**
     * High dynamic range.
     */
    IMAGE_DYNAMIC_RANGE_HDR = 2,
} IMAGE_DYNAMIC_RANGE;

/**
 * @brief Enumerates the types of allocators used to allocate PixelMap memory.
 *
 * @since 15
 */
typedef enum {
    /**
     * The system determines which memory to use to create the PixelMap.
     */
    IMAGE_ALLOCATOR_TYPE_AUTO = 0,
    /**
     * Use DMA buffer to create the PixelMap.
     */
    IMAGE_ALLOCATOR_TYPE_DMA = 1,
    /**
     * Use share memory to create the PixelMap.
     */
    IMAGE_ALLOCATOR_TYPE_SHARE_MEMORY = 2,
} IMAGE_ALLOCATOR_TYPE;

/**
 * @brief Enumerates the cropping and scaling strategies when **desiredSize** and **desiredRegion** are both specified.
 *
 * If the **ImageCropAndScaleStrategy** parameter is not specified in {@link OH_DecodingOptions} and both
 * **desiredRegion** and **desiredSize** are set, the final decoding result may vary slightly due to differences in
 * decoding algorithms used for different image formats.
 *
 * For example, if the original image size is 200x200, and you specify **desiredSize:{width: 150, height: 150},
 * desiredRegion:{x: 0, y: 0, width: 100, height: 100}**, the expectation is to decode the top-left 1/4 region of the
 * original image and then scale the pixelMap size to 150x150.
 *
 * For JPEG and WebP images (as well as some DNG images that decode a JPEG preview within the file and therefore are
 * treated as JPEG format), the system first performs downsampling. For instance, it might downsample by 7/8 and then
 * crop the region based on a 175x175 image size. As a result, the final cropped region will be slightly larger than
 * the top-left 1/4 of the original image.
 *
 * For SVG images, which are vector-based and can be scaled without losing clarity, the system scales the image based
 * on the ratio of **desiredSize** to the original image size and then crops the region. This results in a decoded
 * region that may differ from the exact 1/4 region of the original image.
 *
 * To ensure consistent results when both **desiredRegion** and **desiredSize** are set, set the **ImageCropAndScaleStrategy**
 * parameter to **CROP_FIRST**.
 * 
 * @since 18
 */
typedef enum {
    /**
     * Scales and then crops the image.
     *
     * @since 18
     */
    IMAGE_CROP_AND_SCALE_STRATEGY_SCALE_FIRST = 1,

    /**
     * Crops and then scales the image.
     *
     * @since 18
     */
    IMAGE_CROP_AND_SCALE_STRATEGY_CROP_FIRST = 2,
} Image_CropAndScaleStrategy;

/**
 * @brief Creates the pointer to an OH_ImageSource_Info object.
 * 
 * @param info Double pointer to the OH_ImageSource_Info object created.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_BAD_PARAMETER} info is nullptr.</li>
 *         </ul>
 * @release image_source_native/OH_ImageSourceInfo_Release {info}
 * @since 12
 */
Image_ErrorCode OH_ImageSourceInfo_Create(OH_ImageSource_Info **info)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the image width.
 * 
 * @param info Pointer to an OH_ImageSource_Info object.
 * @param width Pointer to the image width, in px.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or width is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceInfo_GetWidth(OH_ImageSource_Info *info, uint32_t *width)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the image height.
 * 
 * @param info Pointer to an OH_ImageSource_Info object.
 * @param height Pointer to the image height, in px.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or height is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceInfo_GetHeight(OH_ImageSource_Info *info, uint32_t *height)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the dynamic range of an image.
 * 
 * @param info Pointer to an OH_ImageSource_Info object.
 * @param isHdr Pointer to a Boolean that specifies whether the HDR is used.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or isHdr is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceInfo_GetDynamicRange(OH_ImageSource_Info *info, bool *isHdr)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the MIME type of an image source.
 *
 * @param info Pointer to the OH_ImageSource_Info struct.
 * @param mimetype Pointer to the MIME type of the image source.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} info is nullptr, or mimeType is nullptr.
 * @since 20
 */
Image_ErrorCode OH_ImageSourceInfo_GetMimeType(OH_ImageSource_Info *info, Image_MimeType *mimetype)
__attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Releases the pointer to an OH_ImageSource_Info object.
 * 
 * @param info Pointer to an OH_ImageSource_Info object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceInfo_Release(OH_ImageSource_Info *info)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief The OH_DecodingOptions struct describes the decoding options encapsulated at the native layer. The struct is
 * used to set decoding options and is passed in as an input parameter for creating a PixelMap. For details, see 
 * {@link OH_ImageSourceNative_CreatePixelmap}.
 * 
 * @since 12
 */
struct OH_DecodingOptions;
typedef struct OH_DecodingOptions OH_DecodingOptions;

/**
 * @brief Creates the pointer to an OH_DecodingOptions object.
 * 
 * @param  options Double pointer to the OH_DecodingOptions object created.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_BAD_PARAMETER} options is nullptr.</li>
 *         </ul>
 * @release image_source_native/OH_DecodingOptions_Release {options}
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_Create(OH_DecodingOptions **options)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the pixel format.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param pixelFormat Pointer to the pixel format. For details about the available options, see {@link PIXEL_FORMAT}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or pixelFormat is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetPixelFormat(OH_DecodingOptions *options,
    int32_t *pixelFormat)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the pixel format.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param pixelFormat Pixel format. For details about the available options, see {@link PIXEL_FORMAT}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetPixelFormat(OH_DecodingOptions *options,
    int32_t pixelFormat)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the index of an image.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param index Pointer to the index of the image.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or index is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetIndex(OH_DecodingOptions *options, uint32_t *index)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the index for an image.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param index Index of the image.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetIndex(OH_DecodingOptions *options, uint32_t index)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the rotation degree.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param rotate Pointer to the angle to rotate, in degrees.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or rotate is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetRotate(OH_DecodingOptions *options, float *rotate)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the rotation angle.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param rotate Angle to rotate, in degrees.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetRotate(OH_DecodingOptions *options, float rotate)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the desired output size.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param desiredSize Pointer to the desired output size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredSize is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetDesiredSize(OH_DecodingOptions *options,
    Image_Size *desiredSize)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the desired output size.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param desiredSize Pointer to the desired output size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredSize is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetDesiredSize(OH_DecodingOptions *options,
    Image_Size *desiredSize)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the region to decode.
 * Since the corresponding **SetDesiredRegion** function cannot meet the regional decoding requirements, starting from
 * API version 19, you are advised to use {@link OH_DecodingOptions_GetCropRegion} instead.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param desiredRegion Pointer to the region to decode.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredRegion is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetDesiredRegion(OH_DecodingOptions *options,
    Image_Region *desiredRegion)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the region to decode.
 * The actual decoding will process the entire original image, without any regional decoding effect. Starting from API
 * version 19, you are advised to use {@link OH_DecodingOptions_SetCropRegion} instead.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @param desiredRegion Pointer to the region to decode.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options or desiredRegion is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetDesiredRegion(OH_DecodingOptions *options,
    Image_Region *desiredRegion)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the desired dynamic range configured during decoding.
 * 
 * @param options Pointer to an OH_DecodingOptions object.
 * @param desiredDynamicRange Pointer to the desired dynamic range. For details about the available options, see
 * {@link IMAGE_DYNAMIC_RANGE}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredDynamicRange is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_GetDesiredDynamicRange(OH_DecodingOptions *options,
    int32_t *desiredDynamicRange)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Sets the desired dynamic range during decoding.
 * 
 * @param options Pointer to an OH_DecodingOptions object.
 * @param desiredDynamicRange Desired dynamic range. For details about the available options, see
 * {@link IMAGE_DYNAMIC_RANGE}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_SetDesiredDynamicRange(OH_DecodingOptions *options,
    int32_t desiredDynamicRange)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the cropping and scaling strategy used during decoding.
 * 
 * @param options Pointer to an OH_DecodingOptions object.
 * @param cropAndScaleStrategy Pointer to the cropping and scaling strategy that is executed when **desiredSize** and
 *     **desiredRegion** are both specified.
 * @return {@link IMAGE_SUCCESS}: The execution is successful. 
 *     <br>{@link IMAGE_BAD_PARAMETER}: options or cropAndScaleStrategy is a null pointer.
 * @since 18
 */
Image_ErrorCode OH_DecodingOptions_GetCropAndScaleStrategy(OH_DecodingOptions *options,
    int32_t *cropAndScaleStrategy)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the cropping and scaling strategy used during decoding.
 * 
 * @param options Pointer to an OH_DecodingOptions object.
 * @param cropAndScaleStrategy Cropping and scaling strategy that is executed when **desiredSize** and **desiredRegion**
 * are both specified.
 * @return {@link IMAGE_SUCCESS} The execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is a null pointer or cropAndScaleStrategy is not in the range of Image_CropAndScaleStrategy.
 * @since 18
 */
Image_ErrorCode OH_DecodingOptions_SetCropAndScaleStrategy(OH_DecodingOptions *options,
    int32_t cropAndScaleStrategy)
    __attribute__((__availability__(ohos, introduced=18.0.0)));

/**
 * @brief Sets the desired color space for the decoding options.
 * 
 * @param options Pointer to the decoding options.
 * @param colorSpace Color space. For details, see {@link ColorSpaceName}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if options is a null pointer or colorSpace is not supported.
 * @since 20
 */
Image_ErrorCode OH_DecodingOptions_SetDesiredColorSpace(OH_DecodingOptions *options, int32_t colorSpace)
__attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Obtains the color space set in the decoding options.
 * 
 * @param options Pointer to the decoding options.
 * @param colorSpace Pointer to the color space. For details, see {@link ColorSpaceName}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if options or colorSpace is null pointer.
 * @since 20
 */
Image_ErrorCode OH_DecodingOptions_GetDesiredColorSpace(OH_DecodingOptions *options, int32_t *colorSpace)
__attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Sets the cropping region in the decoding options.
 * 
 * @param options Pointer to the decoding options.
 * @param cropRegion Pointer to the cropping region.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if options or cropRegion is null pointer.
 * @since 19
 */
Image_ErrorCode OH_DecodingOptions_SetCropRegion(OH_DecodingOptions *options, Image_Region *cropRegion)
__attribute__((__availability__(ohos, introduced=19.0.0)));

/**
 * @brief Obtains the cropping region in the decoding options.
 * 
 * @param options Pointer to the decoding options.
 * @param cropRegion Pointer to the cropping region.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if options or cropRegion is null pointer.
 * @since 19
 */
Image_ErrorCode OH_DecodingOptions_GetCropRegion(OH_DecodingOptions *options, Image_Region *cropRegion)
__attribute__((__availability__(ohos, introduced=19.0.0)));

/**
 * @brief Releases the pointer to an OH_DecodingOptions object.
 * 
 * @param  options Pointer to an OH_DecodingOptions object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} if options is a null pointer.
 * @since 12
 */
Image_ErrorCode OH_DecodingOptions_Release(OH_DecodingOptions *options)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_ImageSourceNative object based on a URI.
 * 
 * @param uri Pointer to the URI of the image source. Only file URIs or Base64 URIs are accepted. Currently, only
 *     absolute paths are supported.
 * @param uriSize URI length.
 * @param res Double pointer to the OH_ImageSourceNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} if uri is a null pointer.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreateFromUri(char *uri, size_t uriSize, OH_ImageSourceNative **res)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_ImageSourceNative object based on a file descriptor.
 * 
 * @param fd File descriptor.
 * @param res Double pointer to the OH_ImageSourceNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} if fd is invalid.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreateFromFd(int32_t fd, OH_ImageSourceNative **res)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_ImageSourceNative object based on buffer data.
 * The buffer data must be undecoded. Do not pass the pixel buffer data such as RBGA and YUV. If you want to create a
 * PixelMap based on the pixel buffer data, call {@link OH_PixelmapNative_CreatePixelmap}.
 * 
 * @param data Pointer to the buffer data.
 * @param dataSize Size of the buffer.
 * @param res Double pointer to the OH_ImageSourceNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} if data is a null pointer or if dataSize is 0.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreateFromData(uint8_t *data, size_t dataSize, OH_ImageSourceNative **res)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates an image source from data buffer. The data buffer is directly accessed by the image source object,
 * and therefore the data buffer must remain accessible within the lifecycle of the image source object.
 * 
 * @param data Pointer to the data buffer.
 * @param datalength Size of the data buffer.
 * @param imageSource Double pointer to the image source.
 * @return {@link IMAGE_SUCCESS} if the execution is successful. 
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if data or imageSource is a null pointer or if datalength is 0.
 * @since 20
 */

Image_ErrorCode OH_ImageSourceNative_CreateFromDataWithUserBuffer(uint8_t *data, size_t datalength, OH_ImageSourceNative **imageSource)
__attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Creates the pointer to an OH_ImageSourceNative object by using the raw file descriptor of an image resource
 * file.
 * 
 * @param rawFile Pointer to the file descriptor of the raw file.
 * @param res Double pointer to the OH_ImageSourceNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} if rawFile is a null pointer.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreateFromRawFile(RawFileDescriptor *rawFile, OH_ImageSourceNative **res)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_PixelmapNative object based on decoding options.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param  options Pointer to the decoding options.
 * @param pixelmap Double pointer to the OH_PixelmapNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_OPTIONS} unsupported options,
 *         e.g, cannot convert image into desired pixel format.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreatePixelmap(OH_ImageSourceNative *source, OH_DecodingOptions *options,
    OH_PixelmapNative **pixelmap)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates an OH_PixelmapNative object based on decoding options and memory type, where **allocatorType**
 * specifies the memory type of the PixelMap.
 * By default, the system selects an appropriate memory type based on the image type, image size, and platform
 * capability. When processing the returned PixelMap object, consider the impact of stride.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param options Pointer to the decoding options.
 * @param allocator Memory type used by the returned PixelMap.
 * @param pixelmap Double pointer to the OH_PixelmapNative object created at the C++ local layer.
 * @return Result code.
 * @since 15
 */
Image_ErrorCode OH_ImageSourceNative_CreatePixelmapUsingAllocator(OH_ImageSourceNative *source,
    OH_DecodingOptions *options, IMAGE_ALLOCATOR_TYPE allocator, OH_PixelmapNative **pixelmap)
    __attribute__((__availability__(ohos, introduced=15.0.0)));

/**
 * @brief Creates an array of OH_PixelmapNative objects based on decoding options.
 * This function decodes all frames at once. If the number of frames is high or the size of individual frames is large,
 * it can lead to significant memory usage. In these cases, you are advised to use the **Image** component for
 * displaying animations. The **Image** component decodes frames one by one, which uses less memory than this function.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param  options Pointer to the decoding options.
 * @param resVecPixMap Indicates a pointer array to the <b>Pixelmap</b> objects obtained at the C++ native layer.
 * It cannot be a null pointer.
 * @param size Size of the array. You can use {@link OH_ImageSourceNative_GetFrameCount} to obtain the size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or options is nullptr, or resVecPixMap is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_CreatePixelmapList(OH_ImageSourceNative *source, OH_DecodingOptions *options,
    OH_PixelmapNative *resVecPixMap[], size_t size)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_PictureNative object based on decoding options.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param options Pointer to the decoding options.
 * @param picture Double pointer to the OH_PictureNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or picture is nullptr.
 *     <br>{@link IMAGE_DECODE_FAILED} decode failed.
 * @since 13
 */
Image_ErrorCode OH_ImageSourceNative_CreatePicture(OH_ImageSourceNative *source, OH_DecodingOptionsForPicture *options,
    OH_PictureNative **picture)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Creates the pointer to an OH_PictureNative object at the specified index.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param index Index of the image.
 * @param picture Double pointer to the OH_PictureNative object created at the C++ local layer.
 * @return {@link IMAGE_SUCCESS}: The execution is successful.
 *     <br>{@link IMAGE_BAD_SOURCE}: The data source is abnormal.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIMETYPE}: The image format is unsupported.
 *     <br>{@link IMAGE_SOURCE_TOO_LARGE}: The image is too large.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_OPTIONS}: The operation is not supported, for example, invalid index.
 *     <br>{@link IMAGE_DECODE_FAILED}: Decoding fails.
 * @since 20
 */
Image_ErrorCode OH_ImageSourceNative_CreatePictureAtIndex(OH_ImageSourceNative *source, uint32_t index,
    OH_PictureNative **picture)
    __attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Obtains the image delay time list.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param delayTimeList Pointer to the delay time list obtained. It cannot be a null pointer.
 * @param size Size of the delay time list. You can use {@link OH_ImageSourceNative_GetFrameCount} to obtain the size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or delayTimeList is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_GetDelayTimeList(OH_ImageSourceNative *source, int32_t *delayTimeList, size_t size)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the information about an image with a given index.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param index Index of an image. For a GIF image, the value range is [0, N-1], where N indicates the number of GIF
 *     frames. For an image with only one frame, you can pass in **0**.
 * @param info Pointer to the image information obtained, which is an OH_ImageSource_Info struct.
 * For details, see {@link OH_ImageSource_Info}.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or info is nullptr, or failed to get image info.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_GetImageInfo(OH_ImageSourceNative *source, int32_t index,
    OH_ImageSource_Info *info)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the value of an image property.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param key Pointer to the property key. For details, see {@link Image_String}. For details about the value range of **key**, see the definition of {@link OHOS_IMAGE_PROPERTY_XXX}
 *     . The memory must be released after the image source is used. For details, see {@link OH_ImageSourceNative_Release}.
 * @param value Pointer to the value obtained. You can pass in a null pointer with the size set to zero. In this case,
 *     the system will allocate memory, but you must release the memory after use.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or key is nullptr, or value is nullptr.
 *     <br>{@link IMAGE_ALLOC_FAILED} allocate memory failed.
 *     <br>{@link IMAGE_COPY_FAILED} copy memory failed.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_GetImageProperty(OH_ImageSourceNative *source, Image_String *key,
    Image_String *value)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the value of an image property from an <b>ImageSource</b> object. The output value.data is null-terminated. 
 *
 * @param source Pointer to ImageSource.
 * @param key Pointer to the property key.
 * @param value Pointer to the property value. Output Parameter.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 * @since 19
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyWithNull(OH_ImageSourceNative *source, Image_String *key,
    Image_String *value)
    __attribute__((__availability__(ohos, introduced=19.0.0)));

/**
 * @brief Obtains the value of an image property. The output **value.data** is terminated with a string terminator.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param key Pointer to the property key.
 * @param value Pointer to the value obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or key is nullptr, or value is nullptr,
 *         or failed to modify image property because of invalid parameters.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImageProperty(OH_ImageSourceNative *source, Image_String *key,
    Image_String *value)
    __attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Obtains the number of image frames.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @param frameCount Indicates a pointer to the number of frames obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr, or frameCount is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_GetFrameCount(OH_ImageSourceNative *source, uint32_t *frameCount)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Releases the pointer to an OH_ImageSourceNative object.
 * 
 * @param source Pointer to an OH_ImageSourceNative object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} source is nullptr.
 * @since 12
 */
Image_ErrorCode OH_ImageSourceNative_Release(OH_ImageSourceNative *source)
__attribute__((__availability__(ohos, introduced=12.0.0)));

/**
 * @brief Creates the pointer to an OH_DecodingOptionsForPicture object.
 * 
 * @param options Double pointer to the OH_DecodingOptionsForPicture object created.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 13
 */
Image_ErrorCode OH_DecodingOptionsForPicture_Create(OH_DecodingOptionsForPicture **options)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains desired auxiliary pictures in the decoding options (auxiliary pictures contained in **picture**
 * expected to be decoded.)
 * 
 * @param options Pointer to an OH_DecodingOptionsForPicture object.
 * @param desiredAuxiliaryPictures Double pointer to the desired auxiliary pictures.
 * @param length Length of the desired auxiliary pictures.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, desiredAuxiliaryPictures is nullptr,
 *         or length is invalid.
 * @since 13
 */
Image_ErrorCode OH_DecodingOptionsForPicture_GetDesiredAuxiliaryPictures(OH_DecodingOptionsForPicture *options,
    Image_AuxiliaryPictureType **desiredAuxiliaryPictures, size_t *length)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets desired auxiliary pictures in the decoding options.
 * 
 * @param options Pointer to an OH_DecodingOptionsForPicture object.
 * @param desiredAuxiliaryPictures Pointer to the desired auxiliary pictures.
 * @param length Length of the desired auxiliary pictures.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, desiredAuxiliaryPictures is nullptr,
 *         or length is invalid.
 * @since 13
 */
Image_ErrorCode OH_DecodingOptionsForPicture_SetDesiredAuxiliaryPictures(OH_DecodingOptionsForPicture *options,
    Image_AuxiliaryPictureType *desiredAuxiliaryPictures, size_t length)
    __attribute__((__availability__(ohos, introduced=13.0.0)));







/**
 * @brief Releases the pointer to an OH_DecodingOptionsForPicture object.
 * 
 * @param options Pointer to an OH_DecodingOptionsForPicture object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 13
 */
Image_ErrorCode OH_DecodingOptionsForPicture_Release(OH_DecodingOptionsForPicture *options)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
  * @brief Obtains the supported image formats that can be decoded.
  * 
  * @param supportedFormats Double pointer to the supported image formats.
  * @param length Pointer to the size of the array.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if <b>supportedFormats</b> or <b>length</b> is empty.
 * @since 20
 */
Image_ErrorCode OH_ImageSourceNative_GetSupportedFormats(Image_MimeType** supportedFormats, size_t* length)
__attribute__((__availability__(ohos, introduced=20.0.0)));

/**
 * @brief Obtains the value of an image property as short int type.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a short int value.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyShort(OH_ImageSourceNative *source,
    Image_String *key, uint16_t *value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as long int type.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a long int value.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyLong(OH_ImageSourceNative *source,
    Image_String *key, uint32_t *value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as double type.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a double value.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyDouble(OH_ImageSourceNative *source,
    Image_String *key, double *value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Gets the array length of an array type property or the string length of a string type property.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param size Array length for an array type property, string length for a string type property. Output Parameter.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or size is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a array\string value.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyArraySize(OH_ImageSourceNative *source,
    Image_String *key, size_t *size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as string type.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter. The caller needs to manage memory application and release.
 * @param size String length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key, value or size is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a string value.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyString(OH_ImageSourceNative *source,
    Image_String *key, char *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as int array.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter. The caller needs to manage memory application and release.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key, value or size is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a int array.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyIntArray(OH_ImageSourceNative *source,
    Image_String *key, int32_t *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as double array.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter. The caller needs to manage memory application and release.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key, value or size is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a double array.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyDoubleArray(OH_ImageSourceNative *source,
    Image_String *key, double *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the value of an image property as blob.
 *
 * @param source ImageSource from which the property is queried.
 * @param key The property to be queried.
 * @param value Query result. Output Parameter. The caller needs to manage memory application and release.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key, value or size is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a blob.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_GetImagePropertyBlob(OH_ImageSourceNative *source, Image_String *key,
    void *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as short int.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a short int.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyShort(OH_ImageSourceNative *source, Image_String *key,
    uint16_t value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as long int.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a long int.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyLong(OH_ImageSourceNative *source, Image_String *key,
    uint32_t value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as double.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a double.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyDouble(OH_ImageSourceNative *source, Image_String *key,
    double value)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as int array.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not an int array.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyIntArray(OH_ImageSourceNative *source, Image_String *key,
    int32_t *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as double array.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a double array.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyDoubleArray(OH_ImageSourceNative *source, Image_String *key,
    double *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Modify the value of an image property as blob.
 *
 * @param source ImageSource from which the property is modified.
 * @param key The property to be modified.
 * @param value The value set to the property.
 * @param size Array length.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if source, key or value is nullptr.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} if query image property of current mimetype is not supported.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_METADATA} if indicated metadata doesn't exist, or is not a blob.
 * @since 23
 */
Image_ErrorCode OH_ImageSourceNative_ModifyImagePropertyBlob(OH_ImageSourceNative *source, Image_String *key,
    void *value, size_t size)
    __attribute__((__availability__(ohos, introduced=23.0.0)));


/**
 * @brief Defines raw data in an image.
 * It is used in {@link OH_ImageSourceNative_CreateImageRawData}.
 *
 * @since 24
 */
struct OH_ImageRawData;

/**
 * @brief Defines raw data in an image.
 * It is used in {@link OH_ImageSourceNative_CreateImageRawData}.
 *
 * @since 24
 */
typedef struct OH_ImageRawData OH_ImageRawData;

/**
 * @brief Obtains rawData object from an image.
 *         The rawData object usually occupies a large amount of memory because it contains
 *         raw data from the camera. When the rawData object and the data it contains are not used, call the
 *         {@link OH_ImageSourceNative_DestroyImageRawData} method to destroy them in a timely manner.
 *
 * @param source Pointer to the image source.
 * @param rawData Double pointer to the rawData object obtained after decoding.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_SOURCE} Bad source.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if the rawData object is invalid.
 *     <br>{@link IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE} Unsupported MIME type.
 * @since 24
 */
Image_ErrorCode OH_ImageSourceNative_CreateImageRawData(const OH_ImageSourceNative *source, OH_ImageRawData **rawData)
__attribute__((__availability__(ohos, introduced=24.0.0)));

/**
 * @brief Gets binary data from the rawData object.
 *
 * @param rawData Pointer to the rawData object.
 * @param data Pointer to the binary buffer data.
 * @param length Pointer to the length of data obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if the rawData object is invalid.
 * @since 24
 */
Image_ErrorCode OH_ImageSourceNative_GetBufferFromRawData(const OH_ImageRawData *rawData,
    uint8_t **data, size_t *length)
    __attribute__((__availability__(ohos, introduced=24.0.0)));

/**
 * @brief Gets number of bits that each pixel actually occupies in the buffer data.
 *
 * @param rawData Pointer to the rawData object.
 * @param bitsPerPixel Pointer to the bitsPerPixel obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if the rawData object is invalid.
 * @since 24
 */
Image_ErrorCode OH_ImageSourceNative_GetBitsPerPixelFromRawData(const OH_ImageRawData *rawData, uint8_t *bitsPerPixel)
__attribute__((__availability__(ohos, introduced=24.0.0)));

/**
 * @brief Destroys the rawData object.
 *
 * @param rawData Pointer to the rawData object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_SOURCE_INVALID_PARAMETER} if the rawData object is invalid.
 * @since 24
 */
Image_ErrorCode OH_ImageSourceNative_DestroyImageRawData(OH_ImageRawData *rawData)
__attribute__((__availability__(ohos, introduced=24.0.0)));

#ifdef __cplusplus
};
#endif
/** @} */
#endif // INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_SOURCE_NATIVE_H_
