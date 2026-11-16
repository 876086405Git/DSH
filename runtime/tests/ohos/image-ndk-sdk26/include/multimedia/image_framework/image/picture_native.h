/*
 * Copyright (C) 2024 Huawei Device Co., Ltd.
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
 * @brief Provides APIs for obtaining picture data and information.
 *
 * @since 13
 */
/**
 * @file picture_native.h
 *
 * @brief The file declares the APIs for obtaining picture data and information.
 * 
 * @library libpicture.so
 * @kit ImageKit
 * @syscap SystemCapability.Multimedia.Image.Core
 * @since 13
 */
#ifndef INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_PICTURE_NATIVE_H_
#define INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_PICTURE_NATIVE_H_
#include "info/application_target_sdk_version.h"
#include <stdbool.h>

#include "image_common.h"
#include "pixelmap_native.h"
 
#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief The struct is used to perform operations related to the picture.
 * 
 * @since 13
 */
struct OH_PictureNative;

/**
 * @brief The struct is used to perform operations related to the picture.
 * 
 * @since 13
 */
typedef struct OH_PictureNative OH_PictureNative;

/**
 * @brief The struct describes the auxiliary picture, which is used to perform operations related to the auxiliary
 * picture.
 * 
 * @since 13
 */
struct OH_AuxiliaryPictureNative;

/**
 * @brief The struct describes the auxiliary picture, which is used to perform operations related to the auxiliary
 * picture.
 * 
 * @since 13
 */
typedef struct OH_AuxiliaryPictureNative OH_AuxiliaryPictureNative;

/**
 * @brief The struct describes the auxiliary picture information, which is used to perform operations related to the
 * auxiliary picture information.
 * 
 * @since 13
 */
struct OH_AuxiliaryPictureInfo;

/**
 * @brief The struct describes the auxiliary picture information, which is used to perform operations related to the
 * auxiliary picture information.
 * 
 * @since 13
 */
typedef struct OH_AuxiliaryPictureInfo OH_AuxiliaryPictureInfo;

/**
 * @brief Type of the auxiliary picture.
 *
 * @since 13
 */
typedef enum {
    /**
     * Gainmap
     */
    AUXILIARY_PICTURE_TYPE_GAINMAP = 1,
    /**
     * Depth map
     */
    AUXILIARY_PICTURE_TYPE_DEPTH_MAP = 2,
    /**
     * Unrefocus map
     */
    AUXILIARY_PICTURE_TYPE_UNREFOCUS_MAP = 3,
    /**
     * Linear map
     */
    AUXILIARY_PICTURE_TYPE_LINEAR_MAP = 4,
    /**
     * Fragment map
     */
    AUXILIARY_PICTURE_TYPE_FRAGMENT_MAP = 5,
} Image_AuxiliaryPictureType;

/**
 * @brief **OH_ComposeOptions** is the HDR composition option struct encapsulated at the native layer. It is used to
 * specify parameters used for HDR composition, such as the target pixel format.
 * 
 * @since 23
 */
typedef struct OH_ComposeOptions OH_ComposeOptions;

/**
 * @brief Creates an **OH_ComposeOptions** instance.
 * 
 * @param options Pointer to **OH_ComposeOptions**.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 23
 */
Image_ErrorCode OH_ComposeOptions_Create(OH_ComposeOptions **options)
__attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Sets the pixel format in **OH_ComposeOptions**.
 * 
 * @param options Pointer to **OH_ComposeOptions**.
 * @param desiredPixelFormat Pixel format. The RGBA_1010102, YCBCR_P010, and YCRCB_P010 formats are supported.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr, or desiredPixelFormat is not supported.
 * @since 23
 */
Image_ErrorCode OH_ComposeOptions_SetDesiredPixelFormat(OH_ComposeOptions *options, PIXEL_FORMAT desiredPixelFormat)
__attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the pixel format in **OH_ComposeOptions**.
 * 
 * @param options Pointer to **OH_ComposeOptions**.
 * @param desiredPixelFormat Pixel format in the composition options.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr,or desiredPixelFormat is nullptr.
 * @since 23
 */
Image_ErrorCode OH_ComposeOptions_GetDesiredPixelFormat(OH_ComposeOptions *options, PIXEL_FORMAT *desiredPixelFormat)
__attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Releases the pointer to **OH_ComposeOptions**.
 * 
 * @param options Pointer to **OH_ComposeOptions**.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} options is nullptr.
 * @since 23
 */
Image_ErrorCode OH_ComposeOptions_Release(OH_ComposeOptions *options)
__attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Creates the pointer to an OH_PictureNative object.
 * 
 * @param mainPixelmap Pointer to the OH_PixelmapNative object of the main picture.
 * @param picture Double pointer to the OH_PictureNative object created.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} mainPixelmap is nullptr, or picture is nullptr.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_CreatePicture(OH_PixelmapNative *mainPixelmap, OH_PictureNative **picture)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the pointer to the OH_PixelmapNative object of a main picture.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param mainPixelmap Double pointer to the OH_PixelmapNative object obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or mainPixelmap is nullptr.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_GetMainPixelmap(OH_PictureNative *picture, OH_PixelmapNative **mainPixelmap)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the pointer to the OH_PixelmapNative object of an HDR picture.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param hdrPixelmap Double pointer to the OH_PixelmapNative object of the HDR picture.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or hdrPixelmap is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_OPERATION} Unsupported operation, e.g. the picture does not has a gainmap.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_GetHdrComposedPixelmap(OH_PictureNative *picture, OH_PixelmapNative **hdrPixelmap)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the pointer to **OH_PixelmapNative** of an HDR picture based on **OH_ComposeOptions**.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param options Pointer to **OH_ComposeOptions**.
 * @param hdrPixelmap Pointer to **OH_PixelmapNative** of the obtained HDR picture.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or hdrPixelmap is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_OPERATION} Unsupported operation, e.g. the picture does not has a gainmap.
 * @since 23
 */
Image_ErrorCode OH_PictureNative_GetHdrComposedPixelmapWithOptions(OH_PictureNative *picture, OH_ComposeOptions *options, OH_PixelmapNative **hdrPixelmap)
__attribute__((__availability__(ohos, introduced=23.0.0)));

/**
 * @brief Obtains the pointer to the OH_PixelmapNative object of a gain map.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param gainmapPixelmap Double pointer to the OH_PixelmapNative object of the gain map.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or gainmapPixelmap is nullptr.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_GetGainmapPixelmap(OH_PictureNative *picture, OH_PixelmapNative **gainmapPixelmap)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets an auxiliary picture.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param type Type of the auxiliary picture.
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or auxiliaryPicture is nullptr, or the type is invalid.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_SetAuxiliaryPicture(OH_PictureNative *picture, Image_AuxiliaryPictureType type,
    OH_AuxiliaryPictureNative *auxiliaryPicture)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains an auxiliary picture by type.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param type Type of the auxiliary picture.
 * @param auxiliaryPicture Double pointer to the OH_AuxiliaryPictureNative object obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or auxiliaryPicture is nullptr, or the type is invalid.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_GetAuxiliaryPicture(OH_PictureNative *picture, Image_AuxiliaryPictureType type,
    OH_AuxiliaryPictureNative **auxiliaryPicture)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the metadata of a main picture.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param metadataType Metadata type.
 * @param metadata Double pointer to the metadata.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or metadata is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_GetMetadata(OH_PictureNative *picture, Image_MetadataType metadataType,
    OH_PictureMetadata **metadata)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the metadata for a main picture.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @param metadataType Metadata type.
 * @param metadata Pointer to the metadata.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr, or metadata is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_SetMetadata(OH_PictureNative *picture, Image_MetadataType metadataType,
    OH_PictureMetadata *metadata)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the number of auxiliary pictures in a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param count Pointer to the number of auxiliary pictures.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture or count is nullptr, or fail to get the picture.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_GetAuxiliaryPictureCount(OH_PictureNative *picture, uint32_t *count)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Obtains the types of auxiliary pictures in a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param auxiliaryPictureTypes Pointer to the array that receives the auxiliary picture types.
 * @param count On input, the size of auxiliaryPictureTypes array.
 *              On output, the actual number of auxiliary pictures.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture, auxiliaryPictureTypes, or count is nullptr,
 *         or fail to get the picture, or count is smaller than required.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_GetAuxiliaryPictureTypes(OH_PictureNative *picture,
    Image_AuxiliaryPictureType *auxiliaryPictureTypes, uint32_t *count)
    __attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Obtains the number of metadata entries in a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param count Pointer to the number of metadata entries.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture or count is nullptr, or fail to get the picture.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_GetMetadataCount(OH_PictureNative *picture, uint32_t *count)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Obtains the types of metadata in a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param metadataTypes Pointer to the array that receives the metadata types.
 * @param count On input, the size of metadataTypes array.
 *              On output, the actual number of metadata entries.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture, metadataTypes, or count is nullptr,
 *         or fail to get the picture, or count is smaller than required.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_GetMetadataTypes(OH_PictureNative *picture,
    Image_MetadataType *metadataTypes, uint32_t *count)
    __attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Removes an auxiliary picture from a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param type Type of the auxiliary picture to remove.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the auxiliary picture was successfully removed or did not exist.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture is nullptr, or fail to get the picture,
 *         or the type is invalid.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_RemoveAuxiliaryPicture(OH_PictureNative *picture, Image_AuxiliaryPictureType type)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Removes metadata from a Picture object.
 *
 * @param picture Pointer to an OH_PictureNative object.
 * @param type Type of the metadata to remove.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the metadata was successfully removed or did not exist.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} picture is nullptr, or fail to get the picture.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_RemoveMetadata(OH_PictureNative *picture, Image_MetadataType type)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief This structure is used to specify an auxiliary picture copy rule when creating a deep copy of a
 * PictureNative object. It describes how to copy an auxiliary picture from one type to another.
 *
 * @since 26.0.0
 */
typedef struct OH_PictureNative_AuxiliaryPictureCopyItem {
    /**
     * @brief Source auxiliary picture type. It specifies the type of auxiliary picture to be copied from the
     * source picture.
     *
     * @since 26.0.0
     */
    Image_AuxiliaryPictureType srcType;

    /**
     * @brief Destination auxiliary picture type. It specifies the type under which the copied auxiliary picture
     * will be stored in the destination picture.
     *
     * @since 26.0.0
     */
    Image_AuxiliaryPictureType dstType;
} OH_PictureNative_AuxiliaryPictureCopyItem;

/**
 * @brief This structure is used to specify a metadata copy rule when creating a deep copy of a PictureNative object.
 * It describes how to copy metadata from one type to another.
 *
 * @since 26.0.0
 */
typedef struct OH_PictureNative_MetadataCopyItem {
    /**
     * @brief Source metadata type. It specifies the type of metadata to be copied from the source picture.
     *
     * @since 26.0.0
     */
    Image_MetadataType srcType;

    /**
     * @brief Destination metadata type. It specifies the type under which the copied metadata will be stored in the
     * destination picture.
     *
     * @since 26.0.0
     */
    Image_MetadataType dstType;
} OH_PictureNative_MetadataCopyItem;

/**
 * @brief Creates a deep copy of a PictureNative object with specified auxiliary pictures and metadata copied to
 * specified destination types.
 *
 * @param source The source PictureNative object to be copied. Must not be NULL.
 * @param auxiliaryPictureCopyItems An array describing the auxiliary pictures to copy,
 *        including source and destination auxiliary picture types. Can be NULL if
 *        auxiliaryPictureCopyCount is 0.
 * @param auxiliaryPictureCopyCount The number of items in auxiliaryPictureCopyItems.
 * @param metadataCopyItems An array describing the metadata entries to copy,
 *        including source and destination metadata types. Can be NULL if
 *        metadataCopyCount is 0.
 * @param metadataCopyCount The number of items in metadataCopyItems.
 * @param sourceAuxPictureAsMainPixelMap Specifies an auxiliary picture type in the source
 *        picture to be used as the main pixel map in the copied picture. Can be NULL if
 *        the original main pixel map should be used.
 * @param picture Output parameter used to receive the newly created PictureNative object.
 *        The caller is responsible for releasing it when it is no longer needed.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} if source or picture is nullptr, or counts mismatch,
 *         or fail to get the source picture, or Count is not zero but corresponding array is nullptr.</li>
 *         <li>{@link IMAGE_ALLOC_FAILED} memory allocation failed.</li>
 *         </ul>
 * @release picture_native/OH_PictureNative_Release {picture}
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureNative_DeepCopyWithItems(
    OH_PictureNative *source,
    const OH_PictureNative_AuxiliaryPictureCopyItem *auxiliaryPictureCopyItems, uint32_t auxiliaryPictureCopyCount,
    const OH_PictureNative_MetadataCopyItem *metadataCopyItems, uint32_t metadataCopyCount,
    Image_AuxiliaryPictureType *sourceAuxPictureAsMainPixelMap,
    OH_PictureNative **picture)
    __attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Releases the pointer to an OH_PictureNative object.
 * 
 * @param picture Pointer to an OH_PictureNative object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr.
 * @since 13
 */
Image_ErrorCode OH_PictureNative_Release(OH_PictureNative *picture)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Creates the pointer to an OH_AuxiliaryPictureNative object. This API supports only continuous pixel data
 * whose {@link pixel format} is BGRA_8888 and creates an auxiliary picture in RGBA_8888 format.
 * 
 * @param data Pointer to the image data.
 * @param dataLength Length of the image data.
 * @param size Pointer to the size of the auxiliary picture.
 * @param type Type of the auxiliary picture.
 * @param auxiliaryPicture Double pointer to the OH_AuxiliaryPictureNative object created.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} data is nullptr, or dataLength is invalid, or size is nullptr, or the type
 *         is invalid, or auxiliaryPicture is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_Create(uint8_t *data, size_t dataLength, Image_Size *size,
    Image_AuxiliaryPictureType type, OH_AuxiliaryPictureNative **auxiliaryPicture)
    __attribute__((__availability__(ohos, introduced=13.0.0)));


/**
 * @brief Reads pixels in the buffer and writes the result to an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param source Pixels to be written.
 * @param bufferSize Buffer size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or source is nullptr, or the bufferSize is invalid.
 *     <br>{@link IMAGE_ALLOC_FAILED} memory alloc failed.
 *     <br>{@link IMAGE_COPY_FAILED} memory copy failed.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_WritePixels(OH_AuxiliaryPictureNative *auxiliaryPicture, uint8_t *source,
    size_t bufferSize)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Reads pixels of an auxiliary picture and writes the result to the buffer.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param destination Pointer to the buffer to which the pixels of the auxiliary data will be written.
 * @param bufferSize Pointer to the buffer size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or destination is nullptr,
 *         or the bufferSize is invalid.
 *     <br>{@link IMAGE_ALLOC_FAILED} memory alloc failed.
 *     <br>{@link IMAGE_COPY_FAILED} memory copy failed.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_ReadPixels(OH_AuxiliaryPictureNative *auxiliaryPicture, uint8_t *destination,
    size_t *bufferSize)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the type of an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param type Pointer to the auxiliary picture type.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or type is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_GetType(OH_AuxiliaryPictureNative *auxiliaryPicture,
    Image_AuxiliaryPictureType *type)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the information of an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param info Double pointer to the auxiliary picture information.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or info is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_GetInfo(OH_AuxiliaryPictureNative *auxiliaryPicture,
    OH_AuxiliaryPictureInfo **info)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the information for an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param info Pointer to the auxiliary picture information.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or info is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_SetInfo(OH_AuxiliaryPictureNative *auxiliaryPicture,
    OH_AuxiliaryPictureInfo *info)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the metadata of an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param metadataType Metadata type.
 * @param metadata Double pointer to the metadata.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or metadata is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type, or the metadata type does not match the
 *         auxiliary picture type.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_GetMetadata(OH_AuxiliaryPictureNative *auxiliaryPicture,
    Image_MetadataType metadataType, OH_PictureMetadata **metadata)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the metadata for an auxiliary picture.
 * 
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param metadataType Metadata type.
 * @param metadata Pointer to the metadata.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} auxiliaryPicture is nullptr, or metadata is nullptr.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type, or the metadata type does not match the
 *         auxiliary picture type.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_SetMetadata(OH_AuxiliaryPictureNative *auxiliaryPicture,
    Image_MetadataType metadataType, OH_PictureMetadata *metadata)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the OH_PixelmapNative object of an auxiliary picture.
 *
 * @param auxiliaryPicture Pointer to an OH_AuxiliaryPictureNative object.
 * @param pixelmap Double pointer to the OH_PixelmapNative object obtained.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} auxiliaryPicture is nullptr, or pixelmap is nullptr.</li>
 *         <li>{@link IMAGE_GET_IMAGE_DATA_FAILED} fail to get the auxiliary picture or its pixelmap content.</li>
 *         <li>{@link IMAGE_ALLOC_FAILED} memory allocation failed.</li>
 *         </ul>
 * @release pixelmap_native/OH_PixelmapNative_Destroy {pixelmap}
 * @since 26.0.0
 */
Image_ErrorCode OH_AuxiliaryPictureNative_AcquirePixelmap(OH_AuxiliaryPictureNative *auxiliaryPicture,
    OH_PixelmapNative **pixelmap)
    __attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Releases the pointer to an OH_AuxiliaryPictureNative object.
 * 
 * @param picture Pointer to an OH_AuxiliaryPictureNative object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} picture is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureNative_Release(OH_AuxiliaryPictureNative *picture)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Creates an OH_AuxiliaryPictureInfo object.
 * 
 * @param info Double pointer to the OH_AuxiliaryPictureInfo object created.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_Create(OH_AuxiliaryPictureInfo **info)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the auxiliary picture type in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param type Pointer to the type of the auxiliary picture.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or type is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_GetType(OH_AuxiliaryPictureInfo *info, Image_AuxiliaryPictureType *type)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the auxiliary picture type in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param type Type of the auxiliary picture.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or type is invalid.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_SetType(OH_AuxiliaryPictureInfo *info, Image_AuxiliaryPictureType type)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the image size in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param size Pointer to the size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or size is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_GetSize(OH_AuxiliaryPictureInfo *info, Image_Size *size)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the image size in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param size Pointer to the size.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or size is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_SetSize(OH_AuxiliaryPictureInfo *info, Image_Size *size)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the row stride in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param rowStride Pointer to the row stride, which is the number of bytes from one row of pixels in memory to the
 * next row of pixels in memory.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or rowStride is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_GetRowStride(OH_AuxiliaryPictureInfo *info, uint32_t *rowStride)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the row stride in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param rowStride Row stride, which is the number of bytes from one row of pixels in memory to the next row of pixels
 * in memory.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or rowStride is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_SetRowStride(OH_AuxiliaryPictureInfo *info, uint32_t rowStride)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the pixel format in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param pixelFormat Pointer to the pixel format obtained.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr, or pixelFormat is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_GetPixelFormat(OH_AuxiliaryPictureInfo *info, PIXEL_FORMAT *pixelFormat)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets the pixel format in **OH_AuxiliaryPictureInfo**.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @param pixelFormat Pixel format.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_SetPixelFormat(OH_AuxiliaryPictureInfo *info, PIXEL_FORMAT pixelFormat)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Releases the pointer to an OH_AuxiliaryPictureInfo object.
 * 
 * @param info Pointer to the OH_AuxiliaryPictureInfo object.
 * @return {@link IMAGE_SUCCESS} if the execution is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER} info is nullptr.
 * @since 13
 */
Image_ErrorCode OH_AuxiliaryPictureInfo_Release(OH_AuxiliaryPictureInfo *info)
__attribute__((__availability__(ohos, introduced=13.0.0)));









#ifdef __cplusplus
};
#endif
/** @} */
#endif //INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_PICTURE_NATIVE_H_
