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
 * @file image_common.h
 *
 * @brief The file declares the common enums and structs used by the image interface.
 * 
 * @library libimage_common.so
 * @kit ImageKit
 * @syscap SystemCapability.Multimedia.Image.Core
 * @since 12
 */

#ifndef INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_COMMON_H_
#define INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_COMMON_H_
#include "info/application_target_sdk_version.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Defines the image size.
 *
 * @since 12
 */
struct Image_Size {
    /** Image width, in pixels. */
    uint32_t width;
    /** Image height, in pixels. */
    uint32_t height;
};

/**
 * @brief Declaration the image size.
 *
 * @since 12
 */
typedef struct Image_Size Image_Size;

/**
 * @brief Defines the region of the image source to decode.
 *
 * @since 12
 */
struct Image_Region {
    /** X coordinate of the start point, in pixels. */
    uint32_t x;
    /** Y coordinate of the start point, in pixels. */
    uint32_t y;
    /** Width of the region, in pixels. */
    uint32_t width;
    /** Height of the region, in pixels. */
    uint32_t height;
};

/**
 * @brief Declaration the image region.
 *
 * @since 12
 */
typedef struct Image_Region Image_Region;

/**
 * @brief Defines the area of the image pixels to read or write.
 *
 * @since 22
 */
typedef struct Image_PositionArea {
    /** Image pixels data that will be read or written. */
    uint8_t *pixels;
    /** Length of the image pixels data. */
    size_t pixelsSize;
    /** Offset for data reading or writing. */
    uint32_t offset;
    /** Number of bytes per row of the region. */
    uint32_t stride;
    /** Region to read or write. */
    Image_Region region;
} Image_PositionArea;

/**
 * @brief Defines the image scale ratio.
 *
 * @since 22
 */
typedef struct Image_Scale {
    /** Scale ratio on the x-axis. */
    float x;
    /** Scale ratio on the y-axis. */
    float y;
} Image_Scale;

#ifdef __cplusplus
/**
 * @brief The struct describes an image string, which is a carrier for string data.
 * 
 * @since 12
 */
struct Image_String {
    /** data for string type */
    char *data = nullptr;
    /** data length for string type */
    size_t size = 0;
};
#else
/**
 * @brief The struct describes an image string, which is a carrier for string data.
 * 
 * @since 12
 */
struct Image_String {
    /** data for string type */
    char *data;
    /** data length for string type */
    size_t size;
};
#endif

/**
 * @brief Define a PictureMetadata struct type, used for picture metadata.
 * 
 * @since 13
 */
struct OH_PictureMetadata;

/**
 * @brief Define a PictureMetadata struct type, used for picture metadata.
 * 
 * @since 13
 */
typedef struct OH_PictureMetadata OH_PictureMetadata;

/**
 * @brief Defines the property string (in key-value format) of the image source.
 * 
 * @since 12
 */
typedef struct Image_String Image_String;

/**
 * @brief Defines the image encode format.
 *
 * @since 12
 */
typedef struct Image_String Image_MimeType;

/**
 * @brief Enumerates the return values that may be used by the interface.
 *
 * @since 12
 */
typedef enum {
    /** operation success */
    IMAGE_SUCCESS = 0,
    /** invalid parameter */
    IMAGE_BAD_PARAMETER = 401,
    /** unsupported mime type */
    IMAGE_UNSUPPORTED_MIME_TYPE = 7600101,
    /** unknown mime type */
    IMAGE_UNKNOWN_MIME_TYPE = 7600102,
    /** too large data or image */
    IMAGE_TOO_LARGE = 7600103,
    /**
     * @error Failed to get image data.
     * @since 23
     */
    IMAGE_GET_IMAGE_DATA_FAILED = 7600104,
    /**
     * @error PixelMap has been released.
     * @since 26.0.0
     */
    IMAGE_PIXELMAP_RELEASED = 7600105,
    /** @error DMA memory does not exist */
    IMAGE_DMA_NOT_EXIST = 7600173,
    /** @error DMA operation failed */
    IMAGE_DMA_OPERATION_FAILED = 7600174,
    /** unsupported operations */
    IMAGE_UNSUPPORTED_OPERATION = 7600201,
    /** unsupported metadata */
    IMAGE_UNSUPPORTED_METADATA = 7600202,
    /** unsupported conversion */
    IMAGE_UNSUPPORTED_CONVERSION = 7600203,
    /** invalid region */
    IMAGE_INVALID_REGION = 7600204,
    /** @error unsupported memory format
     *  @since 13
     */
    IMAGE_UNSUPPORTED_MEMORY_FORMAT = 7600205,
    /**
     * @error Invalid parameter.
     * @since 19
     */
    IMAGE_INVALID_PARAMETER = 7600206,
    /**
     * @error Unsupported data format
     * @since 22
     */
    IMAGE_UNSUPPORTED_DATA_FORMAT = 7600207,
    /** failed to allocate memory */
    IMAGE_ALLOC_FAILED = 7600301,
    /** memory copy failed */
    IMAGE_COPY_FAILED = 7600302,
    /**
     * @error memory lock or unlock failed
     * @since 15
     */
    IMAGE_LOCK_UNLOCK_FAILED = 7600303,
    /**
     * @error Initialization failed
     * @since 22
     */
    IMAGE_INIT_FAILED = 7600304,
    /**
     * @error Create PixelMap failed
     * @since 22
     */
    IMAGE_CREATE_PIXELMAP_FAILED = 7600305,
    /**
     * @error Data conversion failed.
     * @since 26.0.0
     */
    IMAGE_DATA_CONVERSION_FAILED = 7600306,
    /**
     * @error unsupported allocator mode, e.g., use share memory to create a HDR image as only
     * DMA supported hdr metadata.
     * @since 20
     */
    IMAGE_ALLOCATOR_MODE_UNSUPPORTED = 7600501,
    /** unknown error */
    IMAGE_UNKNOWN_ERROR = 7600901,
    /** decode data source exception */
    IMAGE_BAD_SOURCE = 7700101,
    /**
     * @error unsupported mime type
     * @since 15
     */
    IMAGE_SOURCE_UNSUPPORTED_MIME_TYPE = 7700102,
    /**
     * @error image to large
     * @since 15
     */
    IMAGE_SOURCE_TOO_LARGE = 7700103,
    /**
     * @error unsupported allocator type, e.g., use share memory to decode a HDR image as only
     * DMA supported hdr metadata.
     * @since 15
     */
    IMAGE_SOURCE_UNSUPPORTED_ALLOCATOR_TYPE = 7700201,
    /**
     * @error Unsupported metadata. For example, the property key is not supported,
     *     or the property value is invalid.
     * @since 23
     */
    IMAGE_SOURCE_UNSUPPORTED_METADATA = 7700202,
    /** @error unsupported options, e.g, cannot convert image into desired pixel format.
     * @since 15
     */
    IMAGE_SOURCE_UNSUPPORTED_OPTIONS = 7700203,
    /**
     * @error Invalid parameter.
     * @since 19
     */
    IMAGE_SOURCE_INVALID_PARAMETER = 7700204,
    /** decode failed */
    IMAGE_DECODE_FAILED = 7700301,
    /**
     * @error memory allocation failed
     * @since 15
     */
    IMAGE_SOURCE_ALLOC_FAILED = 7700302,
    /**
     * @error Invalid parameter for ImagePacker.
     * @since 19
     */
    IMAGE_PACKER_INVALID_PARAMETER = 7800202,
    /** encode failed */
    IMAGE_ENCODE_FAILED = 7800301,
    /**
     * @error Invalid parameter for ImageReceiver.
     * @since 20
     */
    IMAGE_RECEIVER_INVALID_PARAMETER = 7900201
} Image_ErrorCode;

/**
 * @brief Enumerates the metadata types.
 * 
 * @since 13
 */
typedef enum {
    /**
     * Exif metadata.
     * 
     * @since 13
     */
    EXIF_METADATA = 1,

    /**
     * Fragment map metadata.
     * 
     * @since 13
     */
    FRAGMENT_METADATA = 2,

    /**
     * GIF image metadata.
     * 
     * @since 20
     */
    GIF_METADATA = 5
} Image_MetadataType;

/**
 * @brief Type of allocator used to allocate memory of a PixelMap.
 *
 * @since 20
 */
typedef enum {
    /**
     * The system determines which memory to use to create the PixelMap.
     *
     * @since 20
     */
    IMAGE_ALLOCATOR_MODE_AUTO = 0,
    /**
     * Use DMA buffer to create the PixelMap.
     *
     * @since 20
     */
    IMAGE_ALLOCATOR_MODE_DMA = 1,
    /**
     * Use share memory to create the PixelMap.
     *
     * @since 20
     */
    IMAGE_ALLOCATOR_MODE_SHARED_MEMORY = 2,
} IMAGE_ALLOCATOR_MODE;

/**
 * @brief Creates the pointer to an OH_PictureMetadata struct.
 * 
 * @param metadataType Metadata type.
 * @param metadata Double pointer to the OH_PictureMetadata struct created.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}: A parameter is incorrect.
 * @since 13
 */
Image_ErrorCode OH_PictureMetadata_Create(Image_MetadataType metadataType, OH_PictureMetadata **metadata)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains a property of metadata based on the key. **value.data** obtained through this API lacks the string
 * terminator **\0**. Please use it with caution.
 * 
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param key Pointer to the key of the property.
 * @param value Pointer to the value of the property.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}: A parameter is incorrect.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA}: The metadata type is not supported, or the metadata type and the
 *     auxiliary picture type do not match.
 * @since 13
 */
Image_ErrorCode OH_PictureMetadata_GetProperty(OH_PictureMetadata *metadata, Image_String *key, Image_String *value)
__attribute__((__availability__(ohos, introduced=13.0.0)));


/**
 * @brief Obtains the metadata value of an OH_PictureMetadata instance. The output **value.data** ends with the string
 * terminator **\0**.
 * 
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param key Pointer to the key of the property.
 * @param value Pointer to the value of the property.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_INVALID_PARAMETER}: The **metadata**, **key**, or **value** parameter is a null pointer.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA}: The metadata type is not supported, or the metadata type and the
 *     auxiliary picture type do not match.
 * @since 19
 */
Image_ErrorCode OH_PictureMetadata_GetPropertyWithNull(OH_PictureMetadata *metadata, Image_String *key, Image_String *value)
__attribute__((__availability__(ohos, introduced=19.0.0)));

/**
 * @brief Sets a property of metadata based on the key.
 * 
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param key Pointer to the key of the property.
 * @param value Pointer to the value of the property.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}: A parameter is incorrect.
 *     <br>{@link IMAGE_UNSUPPORTED_METADATA}: The metadata type is not supported, or the metadata type and the
 *     auxiliary picture type do not match.
 * @since 13
 */
Image_ErrorCode OH_PictureMetadata_SetProperty(OH_PictureMetadata *metadata, Image_String *key, Image_String *value)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Sets blob data in the metadata.
 *
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param blob Pointer to the blob data.
 * @param blobSize Size of the blob data.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} metadata is nullptr, or blob is nullptr, or blobSize is 0.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_OPERATION} failed to set blob data.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureMetadata_SetBlobData(OH_PictureMetadata *metadata, uint8_t *blob, uint32_t blobSize)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Obtains the size of the blob data in the metadata.
 *
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param blobSize Pointer to the size of the blob data.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} metadata or blobSize is nullptr.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureMetadata_GetBlobDataSize(OH_PictureMetadata *metadata, uint32_t *blobSize)
__attribute__((__availability__(ohos, introduced=26.0.0)));
 
/**
 * @brief Obtains blob data from the metadata.
 *
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @param blob Pointer to the blob data obtained.
 * @param blobSize Size of the blob data. The value must be greater than or equal to the value obtained by the
 *     OH_PictureMetadata_GetBlobSize method.
 * @return <ul>
 *         <li>{@link IMAGE_SUCCESS} if the execution is successful.</li>
 *         <li>{@link IMAGE_INVALID_PARAMETER} metadata is nullptr, or blob is nullptr, or blobSize is 0, or blobSize
 *             is less than metadata length.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_METADATA} unsupported metadata type.</li>
 *         <li>{@link IMAGE_UNSUPPORTED_OPERATION} failed to get blob data.</li>
 *         </ul>
 * @since 26.0.0
 */
Image_ErrorCode OH_PictureMetadata_GetBlobData(OH_PictureMetadata *metadata, uint8_t *blob, uint32_t blobSize)
__attribute__((__availability__(ohos, introduced=26.0.0)));

/**
 * @brief Releases the pointer to an OH_PictureMetadata struct.
 * 
 * @param metadata Pointer to an OH_PictureMetadata struct.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}: A parameter is incorrect.
 * @since 13
 */
Image_ErrorCode OH_PictureMetadata_Release(OH_PictureMetadata *metadata)
__attribute__((__availability__(ohos, introduced=13.0.0)));

 

/**
 * @brief Clones metadata.
 * 
 * @param oldMetadata Pointer to an OH_PictureMetadata struct.
 * @param newMetadata Double pointer to the OH_PictureMetadata struct obtained.
 * @return {@link IMAGE_SUCCESS}: The operation is successful.
 *     <br>{@link IMAGE_BAD_PARAMETER}: A parameter is incorrect.
 *     <br>{@link IMAGE_ALLOC_FAILED}: The memory allocation fails.
 *     <br>{@link IMAGE_COPY_FAILED}: The memory copy fails.
 * @since 13
 */
Image_ErrorCode OH_PictureMetadata_Clone(OH_PictureMetadata *oldMetadata, OH_PictureMetadata **newMetadata)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Defines the bmp mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_BMP = "image/bmp";

/**
 * @brief Defines the jpeg mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_JPEG = "image/jpeg";

/**
 * @brief Defines the heic mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_HEIC = "image/heic";

/**
 * @brief Defines the png mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_PNG = "image/png";

/**
 * @brief Defines the webp mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_WEBP = "image/webp";

/**
 * @brief Defines the gif mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_GIF = "image/gif";

/**
 * @brief Defines the x-icon mime type.
 *
 * @since 12
 */
static const char* MIME_TYPE_ICON = "image/x-icon";

/**
 * @brief Defines a pointer to bits per sample, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_BITS_PER_SAMPLE = "BitsPerSample";

/**
 * @brief Defines a pointer to the orientation, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ORIENTATION = "Orientation";

/**
 * @brief Defines a pointer to the image length, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_IMAGE_LENGTH = "ImageLength";

/**
 * @brief Defines a pointer to the image width, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_IMAGE_WIDTH = "ImageWidth";

/**
 * @brief Defines a pointer to the GPS latitude, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_LATITUDE = "GPSLatitude";

/**
 * @brief Defines a pointer to the GPS longitude, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_LONGITUDE = "GPSLongitude";

/**
 * @brief Defines a pointer to the GPS latitude reference information, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_LATITUDE_REF = "GPSLatitudeRef";

/**
 * @brief Defines a pointer to the GPS longitude reference information, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_LONGITUDE_REF = "GPSLongitudeRef";

/**
 * @brief Defines a pointer to the created date and time, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DATE_TIME_ORIGINAL = "DateTimeOriginal";

/**
 * @brief Defines a pointer to the exposure time, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_EXPOSURE_TIME = "ExposureTime";

/**
 * @brief Defines a pointer to the scene type, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SCENE_TYPE = "SceneType";

/**
 * @brief Defines a pointer to the ISO speed ratings, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ISO_SPEED_RATINGS = "ISOSpeedRatings";

/**
 * @brief Defines a pointer to the f-number of the image, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_F_NUMBER = "FNumber";

/**
 * @brief Defines a pointer to the compressed bits per pixel, one of the image properties.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COMPRESSED_BITS_PER_PIXEL = "CompressedBitsPerPixel";

/**
 * @brief The scheme used for image compression.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COMPRESSION = "Compression";

/**
 * @brief Pixel composition, such as RGB or YCbCr.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_PHOTOMETRIC_INTERPRETATION = "PhotometricInterpretation";

/**
 * @brief For each strip, the byte offset of that strip.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_STRIP_OFFSETS = "StripOffsets";

/**
 * @brief The number of components per pixel.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SAMPLES_PER_PIXEL = "SamplesPerPixel";

/**
 * @brief The number of rows per strip of image data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ROWS_PER_STRIP = "RowsPerStrip";

/**
 * @brief The total number of bytes in each strip of image data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_STRIP_BYTE_COUNTS = "StripByteCounts";

/**
 * @brief The image resolution in the width direction.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_X_RESOLUTION = "XResolution";

/**
 * @brief The image resolution in the height direction.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_Y_RESOLUTION = "YResolution";

/**
 * @brief Indicates whether pixel components are recorded in a chunky or planar format.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_PLANAR_CONFIGURATION = "PlanarConfiguration";

/**
 * @brief The unit used to measure XResolution and YResolution.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_RESOLUTION_UNIT = "ResolutionUnit";

/**
 * @brief The transfer function for the image, typically used for color correction.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_TRANSFER_FUNCTION = "TransferFunction";

/**
 * @brief The name and version of the software used to generate the image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SOFTWARE = "Software";

/**
 * @brief The name of the person who created the image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ARTIST = "Artist";

/**
 * @brief The chromaticity of the white point of the image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_WHITE_POINT = "WhitePoint";

/**
 * @brief The chromaticity of the primary colors of the image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_PRIMARY_CHROMATICITIES = "PrimaryChromaticities";

/**
 * @brief The matrix coefficients for transformation from RGB to YCbCr image data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_YCBCR_COEFFICIENTS = "YCbCrCoefficients";

/**
 * @brief The sampling ratio of chrominance components to the luminance component.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_YCBCR_SUB_SAMPLING = "YCbCrSubSampling";

/**
 * @brief The position of chrominance components in relation to the luminance component.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_YCBCR_POSITIONING = "YCbCrPositioning";

/**
 * @brief The reference black point value and reference white point value.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_REFERENCE_BLACK_WHITE = "ReferenceBlackWhite";

/**
 * @brief Copyright information for the image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COPYRIGHT = "Copyright";

/**
 * @brief The offset to the start byte (SOI) of JPEG compressed thumbnail data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_JPEG_INTERCHANGE_FORMAT = "JPEGInterchangeFormat";

/**
 * @brief The number of bytes of JPEG compressed thumbnail data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_JPEG_INTERCHANGE_FORMAT_LENGTH = "JPEGInterchangeFormatLength";

/**
 * @brief The class of the program used by the camera to set exposure when the picture is taken.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_EXPOSURE_PROGRAM = "ExposureProgram";

/**
 * @brief Indicates the spectral sensitivity of each channel of the camera used.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SPECTRAL_SENSITIVITY = "SpectralSensitivity";

/**
 * @brief Indicates the Opto-Electric Conversion Function (OECF) specified in ISO 14524.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_OECF = "OECF";

/**
 * @brief The version of the Exif standard supported.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_EXIF_VERSION = "ExifVersion";

/**
 * @brief The date and time when the image was stored as digital data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DATE_TIME_DIGITIZED = "DateTimeDigitized";

/**
 * @brief Information specific to compressed data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COMPONENTS_CONFIGURATION = "ComponentsConfiguration";

/**
 * @brief The shutter speed, expressed as an APEX (Additive System of Photographic Exposure) value.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SHUTTER_SPEED_VALUE = "ShutterSpeedValue";

/**
 * @brief The brightness value of the image, in APEX units.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_BRIGHTNESS_VALUE = "BrightnessValue";

/**
 * @brief The smallest F number of lens.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_MAX_APERTURE_VALUE = "MaxApertureValue";

/**
 * @brief The distance to the subject, measured in meters.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBJECT_DISTANCE = "SubjectDistance";

/**
 * @brief This tag indicate the location and area of the main subject in the overall scene.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBJECT_AREA = "SubjectArea";

/**
 * @brief A tag for manufacturers of Exif/DCF writers to record any desired information.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_MAKER_NOTE = "MakerNote";

/**
 * @brief A tag for record fractions of seconds for the DateTime tag.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBSEC_TIME = "SubsecTime";

/**
 * @brief A tag used to record fractions of seconds for the DateTimeOriginal tag.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBSEC_TIME_ORIGINAL = "SubsecTimeOriginal";

/**
 * @brief A tag used to record fractions of seconds for the DateTimeDigitized tag.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBSEC_TIME_DIGITIZED = "SubsecTimeDigitized";

/**
 * @brief This tag denotes the Flashpix format version supported by an FPXR file, enhancing device compatibility.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FLASHPIX_VERSION = "FlashpixVersion";

/**
 * @brief The color space information tag, often recorded as the color space specifier.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COLOR_SPACE = "ColorSpace";

/**
 * @brief The name of an audio file related to the image data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_RELATED_SOUND_FILE = "RelatedSoundFile";

/**
 * @brief Strobe energy at image capture, in BCPS.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FLASH_ENERGY = "FlashEnergy";

/**
 * @brief Camera or input device spatial frequency table.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SPATIAL_FREQUENCY_RESPONSE = "SpatialFrequencyResponse";

/**
 * @brief Pixels per FocalPlaneResolutionUnit in the image width.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FOCAL_PLANE_X_RESOLUTION = "FocalPlaneXResolution";

/**
 * @brief Pixels per FocalPlaneResolutionUnit in the image height.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FOCAL_PLANE_Y_RESOLUTION = "FocalPlaneYResolution";

/**
 * @brief Unit for measuring FocalPlaneXResolution and FocalPlaneYResolution.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FOCAL_PLANE_RESOLUTION_UNIT = "FocalPlaneResolutionUnit";

/**
 * @brief Location of the main subject, relative to the left edge.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBJECT_LOCATION = "SubjectLocation";

/**
 * @brief Selected exposure index at capture.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_EXPOSURE_INDEX = "ExposureIndex";

/**
 * @brief Image sensor type on the camera.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SENSING_METHOD = "SensingMethod";

/**
 * @brief Indicates the image source.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FILE_SOURCE = "FileSource";

/**
 * @brief Color filter array (CFA) geometric pattern of the image sensor.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_CFA_PATTERN = "CFAPattern";

/**
 * @brief Indicates special processing on image data.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_CUSTOM_RENDERED = "CustomRendered";

/**
 * @brief Exposure mode set when the image was shot.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_EXPOSURE_MODE = "ExposureMode";

/**
 * @brief Digital zoom ratio at the time of capture.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DIGITAL_ZOOM_RATIO = "DigitalZoomRatio";

/**
 * @brief Type of scene captured.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SCENE_CAPTURE_TYPE = "SceneCaptureType";

/**
 * @brief Degree of overall image gain adjustment.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GAIN_CONTROL = "GainControl";

/**
 * @brief Direction of contrast processing applied by the camera.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_CONTRAST = "Contrast";

/**
 * @brief Direction of saturation processing applied by the camera.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SATURATION = "Saturation";

/**
 * @brief The direction of sharpness processing applied by the camera.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SHARPNESS = "Sharpness";

/**
 * @brief Information on picture-taking conditions for a specific camera model.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DEVICE_SETTING_DESCRIPTION = "DeviceSettingDescription";

/**
 * @brief Indicates the distance range to the subject.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBJECT_DISTANCE_RANGE = "SubjectDistanceRange";

/**
 * @brief An identifier uniquely assigned to each image.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_IMAGE_UNIQUE_ID = "ImageUniqueID";

/**
 * @brief The version of the GPSInfoIFD.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_VERSION_ID = "GPSVersionID";

/**
 * @brief Reference altitude used for GPS altitude.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_ALTITUDE_REF = "GPSAltitudeRef";

/**
 * @brief The altitude based on the reference in GPSAltitudeRef.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_ALTITUDE = "GPSAltitude";

/**
 * @brief The GPS satellites used for measurements.
 * Used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_SATELLITES = "GPSSatellites";

/**
 * @brief The status of the GPS receiver when the image is recorded.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_STATUS = "GPSStatus";

/**
 * @brief The GPS measurement mode.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_MEASURE_MODE = "GPSMeasureMode";

/**
 * @brief The GPS DOP (data degree of precision).
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DOP = "GPSDOP";

/**
 * @brief The unit used to express the GPS receiver speed of movement.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_SPEED_REF = "GPSSpeedRef";

/**
 * @brief The speed of GPS receiver movement.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_SPEED = "GPSSpeed";

/**
 * @brief The reference for giving the direction of GPS receiver movement.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_TRACK_REF = "GPSTrackRef";

/**
 * @brief The direction of GPS receiver movement.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_TRACK = "GPSTrack";

/**
 * @brief The reference for the image's direction.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_IMG_DIRECTION_REF = "GPSImgDirectionRef";

/**
 * @brief The direction of the image when captured.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_IMG_DIRECTION = "GPSImgDirection";

/**
 * @brief Geodetic survey data used by the GPS receiver.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_MAP_DATUM = "GPSMapDatum";

/**
 * @brief Indicates the latitude reference of the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_LATITUDE_REF = "GPSDestLatitudeRef";

/**
 * @brief The latitude of the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_LATITUDE = "GPSDestLatitude";

/**
 * @brief Indicates the longitude reference of the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_LONGITUDE_REF = "GPSDestLongitudeRef";

/**
 * @brief A character string recording the name of the method used for location finding.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_PROCESSING_METHOD = "GPSProcessingMethod";

/**
 * @brief A character string recording the name of the GPS area.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_AREA_INFORMATION = "GPSAreaInformation";

/**
 * @brief This field denotes if differential correction was applied to GPS data, crucial for precise location accuracy.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DIFFERENTIAL = "GPSDifferential";

/**
 * @brief The serial number of the camera body.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_BODY_SERIAL_NUMBER = "BodySerialNumber";

/**
 * @brief The name of the camera owner.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_CAMERA_OWNER_NAME = "CameraOwnerName";

/**
 * @brief The name of the camera owner.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_COMPOSITE_IMAGE = "CompositeImage";

/**
 * @brief The DNGVersion tag encodes the four-tier version number for DNG specification compliance.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DNG_VERSION = "DNGVersion";

/**
 * @brief The longitude of the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_LONGITUDE = "GPSDestLongitude";

/**
 * @brief The reference for the bearing to the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_BEARING_REF = "GPSDestBearingRef";

/**
 * @brief The bearing to the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_BEARING = "GPSDestBearing";

/**
 * @brief The measurement unit for the distance to the target point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_DISTANCE_REF = "GPSDestDistanceRef";

/**
 * @brief The distance to the destination point.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_DEST_DISTANCE = "GPSDestDistance";

/**
 * @brief DefaultCropSize specifies the final image size in raw coordinates, accounting for extra edge pixels.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_DEFAULT_CROP_SIZE = "DefaultCropSize";

/**
 * @brief Indicates the value of coefficient gamma.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GAMMA = "Gamma";

/**
 * @brief The tag indicate the ISO speed latitude yyy value of the camera or input device that is defined in ISO 12232.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ISO_SPEED_LATITUDEYYY = "ISOSpeedLatitudeyyy";

/**
 * @brief The tag indicate the ISO speed latitude zzz value of the camera or input device that is defined in ISO 12232.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_ISO_SPEED_LATITUDEZZZ = "ISOSpeedLatitudezzz";

/**
 * @brief The manufacturer of the lens.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_LENS_MAKE = "LensMake";

/**
 * @brief The model name of the lens.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_LENS_MODEL = "LensModel";

/**
 * @brief The serial number of the lens.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_LENS_SERIAL_NUMBER = "LensSerialNumber";

/**
 * @brief Specifications of the lens used.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_LENS_SPECIFICATION = "LensSpecification";

/**
 * @brief This tag provides a broad description of the data type in this subfile.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_NEW_SUBFILE_TYPE = "NewSubfileType";

/**
 * @brief This tag records the UTC offset for the DateTime tag, ensuring accurate timestamps regardless of location.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_OFFSET_TIME = "OffsetTime";

/**
 * @brief This tag logs the UTC offset when the image was digitized, aiding in accurate timestamp adjustment.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_OFFSET_TIME_DIGITIZED = "OffsetTimeDigitized";

/**
 * @brief This tag records the UTC offset when the original image was created, crucial for time-sensitive applications.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_OFFSET_TIME_ORIGINAL = "OffsetTimeOriginal";

/**
 * @brief Exposure times of source images for a composite image.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SOURCE_EXPOSURE_TIMES_OF_COMPOSITE_IMAGE = "SourceExposureTimesOfCompositeImage";

/**
 * @brief The number of source images used for a composite image.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SOURCE_IMAGE_NUMBER_OF_COMPOSITE_IMAGE = "SourceImageNumberOfCompositeImage";

/**
 * @brief This deprecated field signifies the type of data in this subfile. Use the NewSubfileType field instead.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SUBFILE_TYPE = "SubfileType";

/**
 * @brief This tag indicates horizontal positioning errors in meters.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GPS_H_POSITIONING_ERROR = "GPSHPositioningError";

/**
 * @brief This tag indicates the sensitivity of the camera or input device when the image was shot.
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_PHOTOGRAPHIC_SENSITIVITY = "PhotographicSensitivity";

/**
 * @brief Burst Number
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_BURST_NUMBER = "HwMnoteBurstNumber";

/**
 * @brief Face Conf
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_CONF = "HwMnoteFaceConf";

/**
 * @brief Face Leye Center
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_LEYE_CENTER = "HwMnoteFaceLeyeCenter";

/**
 * @brief Face Mouth Center
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_MOUTH_CENTER = "HwMnoteFaceMouthCenter";

/**
 * @brief Face Pointer
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_POINTER = "HwMnoteFacePointer";

/**
 * @brief Face Rect
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_RECT = "HwMnoteFaceRect";

/**
 * @brief Face Reye Center
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_REYE_CENTER = "HwMnoteFaceReyeCenter";

/**
 * @brief Face Smile Score
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_SMILE_SCORE = "HwMnoteFaceSmileScore";

/**
 * @brief Face Version
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FACE_VERSION = "HwMnoteFaceVersion";

/**
 * @brief Front Camera
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_FRONT_CAMERA = "HwMnoteFrontCamera";

/**
 * @brief Scene Pointer
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SCENE_POINTER = "HwMnoteScenePointer";

/**
 * @brief Scene Version
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_SCENE_VERSION = "HwMnoteSceneVersion";

/**
 * @brief Is Xmage Supported
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_IS_XMAGE_SUPPORTED = "HwMnoteIsXmageSupported";

/**
 * @brief Xmage Mode
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_XMAGE_MODE = "HwMnoteXmageMode";

/**
 * @brief Xmage X1 Coordinate
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_XMAGE_LEFT = "HwMnoteXmageLeft";

/**
 * @brief Xmage Y1 Coordinate
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_XMAGE_TOP = "HwMnoteXmageTop";

/**
 * @brief Xmage X2 Coordinate
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_XMAGE_RIGHT = "HwMnoteXmageRight";

/**
 * @brief Xmage Y2 Coordinate
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_XMAGE_BOTTOM = "HwMnoteXmageBottom";

/**
 * @brief Cloud Enhancement Mode
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_CLOUD_ENHANCEMENT_MODE = "HwMnoteCloudEnhancementMode";

/**
 * @brief Wind Snapshot Mode
 * It is used in {@link OH_ImageSource_GetImageProperty} and {@link OH_ImageSource_ModifyImageProperty}.
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_WIND_SNAPSHOT_MODE = "HwMnoteWindSnapshotMode";


/**
 * @brief Gif Loop Count
 * It is used in {@link OH_ImageSource_GetImageProperty}.
 * If infinite loop returns 0, other values represent the number of loops
 *
 * @since 12
 */
static const char *OHOS_IMAGE_PROPERTY_GIF_LOOP_COUNT = "GIFLoopCount";

/**
 * @brief X in original
 * It is used in {@link OH_ImageSource_GetImageProperty}.
 * The top left corner of the fragment image is at the X-coordinate of the original image
 *
 * @since 13
 */
static const char *OHOS_IMAGE_PROPERTY_X_IN_ORIGINAL = "XInOriginal";

/**
 * @brief Y in original
 * It is used in {@link OH_ImageSource_GetImageProperty}.
 * The top left corner of the fragment image is at the Y-coordinate of the original image
 *
 * @since 13
 */
static const char *OHOS_IMAGE_PROPERTY_Y_IN_ORIGINAL = "YInOriginal";

/**
 * @brief Fragment map width
 * It is used in {@link OH_ImageSource_GetImageProperty}.
 * The width of the fragment image
 *
 * @since 13
 */
static const char *OHOS_IMAGE_PROPERTY_FRAGMENT_WIDTH = "FragmentImageWidth";

/**
 * @brief Fragment map height
 * It is used in {@link OH_ImageSource_GetImageProperty}.
 * The height of the fragment image
 *
 * @since 13
 */
static const char *OHOS_IMAGE_PROPERTY_FRAGMENT_HEIGHT = "FragmentImageHeight";

/**
 * @brief Delay of each frame in a GIF image, in milliseconds.
 *
 * @since 20
 */

static const char *IMAGE_PROPERTY_GIF_DELAY_TIME = "GifDelayTime";

/**
 * @brief Disposal type of each frame in a GIF image.
 *
 * @since 20
 */
static const char *IMAGE_PROPERTY_GIF_DISPOSAL_TYPE = "GifDisposalType";

/**
 * @brief The dng version.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DNG_VERSION = "DNGVersion";

/**
 * @brief The dng backward version.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DNG_BACKWARD_VERSION =
    "DNGBackwardVersion";

/**
 * @brief A unique camera model.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_UNIQUE_CAMERA_MODEL = "UniqueCameraModel";

/**
 * @brief A localized camera model.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_LOCALIZED_CAMERA_MODEL =
    "LocalizedCameraModel";

/**
 * @brief The CFA (color filter array) plane color.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CFA_PLANE_COLOR = "CFAPlaneColor";

/**
 * @brief The CFA (color filter array) layout.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CFA_LAYOUT = "CFALayout";

/**
 * @brief The linearization table.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_LINEARIZATION_TABLE = "LinearizationTable";

/**
 * @brief The black level repeat dimension.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BLACK_LEVEL_REPEAT_DIM =
    "BlackLevelRepeatDim";

/**
 * @brief The zero‑light encoding level.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BLACK_LEVEL = "BlackLevel";

/**
 * @brief The black level delta H.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BLACK_LEVEL_DELTA_H = "BlackLevelDeltaH";

/**
 * @brief The black level delta V.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BLACK_LEVEL_DELTA_V = "BlackLevelDeltaV";

/**
 * @brief The white level.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_WHITE_LEVEL = "WhiteLevel";

/**
 * @brief The default scale.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DEFAULT_SCALE = "DefaultScale";

/**
 * @brief The default crop origin.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DEFAULT_CROP_ORIGIN = "DefaultCropOrigin";

/**
 * @brief The default crop size.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DEFAULT_CROP_SIZE = "DefaultCropSize";

/**
 * @brief A transformation matrix under the first calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_COLOR_MATRIX1 = "ColorMatrix1";

/**
 * @brief A transformation matrix under the second calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_COLOR_MATRIX2 = "ColorMatrix2";

/**
 * @brief A calibration matrix under the first calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CAMERA_CALIBRATION1 = "CameraCalibration1";

/**
 * @brief A calibration matrix under the second calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CAMERA_CALIBRATION2 = "CameraCalibration2";

/**
 * @brief A dimensionality reduction matrix under the first calibration
 * illuminant. It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize}
 * and {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_REDUCTION_MATRIX1 = "ReductionMatrix1";

/**
 * @brief A dimensionality reduction matrix under the second calibration
 * illuminant. It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_REDUCTION_MATRIX2 = "ReductionMatrix2";

/**
 * @brief The analog balance.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ANALOG_BALANCE = "AnalogBalance";

/**
 * @brief The as‑shot neutral.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_AS_SHOT_NEUTRAL = "AsShotNeutral";

/**
 * @brief The as‑shot white point encoded as x-y chromaticity coordinates.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_AS_SHOT_WHITEXY = "AsShotWhiteXY";

/**
 * @brief The baseline exposure.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BASELINE_EXPOSURE = "BaselineExposure";

/**
 * @brief The baseline noise.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BASELINE_NOISE = "BaselineNoise";

/**
 * @brief The baseline sharpness.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BASELINE_SHARPNESS = "BaselineSharpness";

/**
 * @brief The Bayer green split.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BAYER_GREEN_SPLIT = "BayerGreenSplit";

/**
 * @brief The linear response limit.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_LINEAR_RESPONSE_LIMIT =
    "LinearResponseLimit";

/**
 * @brief The serial number of the camera.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CAMERA_SERIAL_NUMBER =
    "CameraSerialNumber";

/**
 * @brief Information about the lens.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_LENS_INFO = "LensInfo";

/**
 * @brief The chroma blur radius.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CHROMA_BLUR_RADIUS = "ChromaBlurRadius";

/**
 * @brief The anti‑alias strength.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ANTI_ALIAS_STRENGTH = "AntiAliasStrength";

/**
 * @brief The shadow scale.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_SHADOW_SCALE = "ShadowScale";

/**
 * @brief The private data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DNG_PRIVATE_DATA = "DNGPrivateData";

/**
 * @brief Whether the EXIF MakerNote tag is safe.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_MAKER_NOTE_SAFETY = "MakerNoteSafety";

/**
 * @brief The first calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CALIBRATION_ILLUMINANT1 =
    "CalibrationIlluminant1";

/**
 * @brief The second calibration illuminant.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CALIBRATION_ILLUMINANT2 =
    "CalibrationIlluminant2";

/**
 * @brief The best quality scale.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BEST_QUALITY_SCALE = "BestQualityScale";

/**
 * @brief The unique identifier of raw image data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_RAW_DATA_UNIQUE_ID = "RawDataUniqueID";

/**
 * @brief The original raw file name.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_RAW_FILE_NAME =
    "OriginalRawFileName";

/**
 * @brief The original raw file data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_RAW_FILE_DATA =
    "OriginalRawFileData";

/**
 * @brief The active area.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ACTIVE_AREA = "ActiveArea";

/**
 * @brief The masked areas.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_MASKED_AREAS = "MaskedAreas";

/**
 * @brief An ICC profile.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_AS_SHOT_ICC_PROFILE = "AsShotICCProfile";

/**
 * @brief The as‑shot pre‑profile matrix.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_AS_SHOT_PRE_PROFILE_MATRIX =
    "AsShotPreProfileMatrix";

/**
 * @brief The current ICC profile.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CURRENT_ICC_PROFILE = "CurrentICCProfile";

/**
 * @brief The current pre‑profile matrix.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CURRENT_PRE_PROFILE_MATRIX =
    "CurrentPreProfileMatrix";

/**
 * @brief The colorimetric reference.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_COLORIMETRIC_REFERENCE =
    "ColorimetricReference";

/**
 * @brief The camera calibration signature.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_CAMERA_CALIBRATION_SIGNATURE =
    "CameraCalibrationSignature";

/**
 * @brief The profile calibration signature.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_CALIBRATION_SIGNATURE =
    "ProfileCalibrationSignature";

/**
 * @brief The extra camera profiles.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_EXTRA_CAMERA_PROFILES =
    "ExtraCameraProfiles";

/**
 * @brief The as‑shot camera profile name.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_AS_SHOT_PROFILE_NAME = "AsShotProfileName";

/**
 * @brief The applied noise reduction.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_NOISE_REDUCTION_APPLIED =
    "NoiseReductionApplied";

/**
 * @brief The profile name.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_NAME = "ProfileName";

/**
 * @brief The profile hue/saturation map dimensions.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_HUE_SAT_MAP_DIMS =
    "ProfileHueSatMapDims";

/**
 * @brief The first hue/saturation mapping table data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_HUE_SAT_MAP_DATA1 =
    "ProfileHueSatMapData1";

/**
 * @brief The second hue/saturation mapping table data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_HUE_SAT_MAP_DATA2 =
    "ProfileHueSatMapData2";

/**
 * @brief The profile tone curve.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_TONE_CURVE = "ProfileToneCurve";

/**
 * @brief The profile embedding policy.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_EMBED_POLICY =
    "ProfileEmbedPolicy";

/**
 * @brief The profile copyright.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_COPYRIGHT = "ProfileCopyright";

/**
 * @brief The first forward matrix.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_FORWARD_MATRIX1 = "ForwardMatrix1";

/**
 * @brief The second forward matrix.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_FORWARD_MATRIX2 = "ForwardMatrix2";

/**
 * @brief The preview application name.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_APPLICATION_NAME =
    "PreviewApplicationName";

/**
 * @brief The preview application version.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_APPLICATION_VERSION =
    "PreviewApplicationVersion";

/**
 * @brief The preview settings name.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_SETTINGS_NAME =
    "PreviewSettingsName";

/**
 * @brief The preview settings digest.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_SETTINGS_DIGEST =
    "PreviewSettingsDigest";

/**
 * @brief The preview color space.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_COLOR_SPACE = "PreviewColorSpace";

/**
 * @brief The preview date and time.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PREVIEW_DATE_TIME = "PreviewDateTime";

/**
 * @brief An MD5 digest of the raw image data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_RAW_IMAGE_DIGEST = "RawImageDigest";

/**
 * @brief An MD5 digest of the data stored in the OriginalRawFileData.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_RAW_FILE_DIGEST =
    "OriginalRawFileDigest";

/**
 * @brief The sub-tile block size.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_SUB_TILE_BLOCK_SIZE = "SubTileBlockSize";

/**
 * @brief The row interleave factor.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyShort} and
 * {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ROW_INTERLEAVE_FACTOR =
    "RowInterleaveFactor";

/**
 * @brief The profile lookup table dimensions.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_LOOK_TABLE_DIMS =
    "ProfileLookTableDims";

/**
 * @brief The profile lookup table data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_LOOK_TABLE_DATA =
    "ProfileLookTableData";

/**
 * @brief The first opcode list.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_OPCODE_LIST1 = "OpcodeList1";

/**
 * @brief The second opcode list.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_OPCODE_LIST2 = "OpcodeList2";

/**
 * @brief The third opcode list.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyBlob}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_OPCODE_LIST3 = "OpcodeList3";

/**
 * @brief The noise profile.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_NOISE_PROFILE = "NoiseProfile";

/**
 * @brief The original default final size.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_DEFAULT_FINAL_SIZE =
    "OriginalDefaultFinalSize";

/**
 * @brief The original best quality final size.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_BEST_QUALITY_FINAL_SIZE =
    "OriginalBestQualityFinalSize";

/**
 * @brief The original default crop size.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyDoubleArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_ORIGINAL_DEFAULT_CROP_SIZE =
    "OriginalDefaultCropSize";

/**
 * @brief The profile hue‑saturation map encoding.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_HUE_SAT_MAP_ENCODING =
    "ProfileHueSatMapEncoding";

/**
 * @brief The profile lookup table encoding.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_PROFILE_LOOK_TABLE_ENCODING =
    "ProfileLookTableEncoding";

/**
 * @brief The baseline exposure offset.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_BASELINE_EXPOSURE_OFFSET =
    "BaselineExposureOffset";

/**
 * @brief The default black render.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyLong}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DEFAULT_BLACK_RENDER =
    "DefaultBlackRender";

/**
 * @brief A modified MD5 digest of the raw image data.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyString}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_NEW_RAW_IMAGE_DIGEST = "NewRawImageDigest";

/**
 * @brief The gain between the main raw IFD and the preview IFD.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyDouble}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_RAW_TO_PREVIEW_GAIN = "RawToPreviewGain";

/**
 * @brief The default user crop.
 * It is used in {@link OH_ImageSourceNative_GetImagePropertyArraySize} and
 * {@link OH_ImageSourceNative_GetImagePropertyIntArray}.
 *
 * @since 24
 */
static const char *OHOS_DNG_PROPERTY_DEFAULT_USER_CROP = "DefaultUserCrop";

#ifdef __cplusplus
};
#endif
/** @} */

#endif // INTERFACES_KITS_NATIVE_INCLUDE_IMAGE_IMAGE_COMMON_H_
