/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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
 * @addtogroup NativeColorSpaceManager
 * @{
 *
 * @brief Provides the native colorSpaceManager capability.
 *
 * @since 13
 * @version 1.0
 */

/**
 * @file native_color_space_manager.h
 *
 * @brief This file declares the functions for creating and using a color space.
 *
 * @kit ArkGraphics2D
 * @library libnative_color_space_manager.so
 * @syscap SystemCapability.Graphic.Graphic2D.ColorManager.Core
 * @since 13
 * @version 1.0
 */

#ifndef C_INCLUDE_NATIVE_COLOR_SPACE_MANAGER_H_
#define C_INCLUDE_NATIVE_COLOR_SPACE_MANAGER_H_

#include "info/application_target_sdk_version.h"
#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Provides the declaration of an **OH_NativeColorSpaceManager** struct.
 *
 * @since 13
 */
typedef struct OH_NativeColorSpaceManager OH_NativeColorSpaceManager;

/**
 * @brief Defines an enum for the color space names.
 *
 * @since 13
 */
typedef enum {
    /**
     * Unknown color space.
     */
    NONE = 0,
    /**
     * Color space based on Adobe RGB.
     */
    ADOBE_RGB = 1,
    /**
     * Color space based on SMPTE RP 431-2-2007 and IEC 61966-2.1:1999.
     */
    DCI_P3 = 2,
    /**
     * Color space based on SMPTE RP 431-2-2007 and IEC 61966-2.1:1999.
     */
    DISPLAY_P3 = 3,
    /**
     * Standard Red Green Blue (SRGB) color space based on IEC 61966-2.1:1999.
     */
    SRGB = 4,
    /**
     * Color space based on ITU-R BT.709.
     */
    BT709 = 6,
    /**
     * Color space based on ITU-R BT.601.
     */
    BT601_EBU = 7,
    /**
     * Color space based on ITU-R BT.601.
     */
    BT601_SMPTE_C = 8,
    /**
     * Color space based on ITU-R BT.2020.
     */
    BT2020_HLG = 9,
    /**
     * Color space based on ITU-R BT.2020.
     */
    BT2020_PQ = 10,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of HLG, and the color range of Full.
     */
    P3_HLG = 11,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of PQ, and the color range of Full.
     */
    P3_PQ = 12,
    /**
     * Color space with the color primaries of ADOBE_RGB, the transfer characteristics of ADOBE_RGB, and the color
     * range of LIMIT.
     */
    ADOBE_RGB_LIMIT = 13,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of SRGB, and the color range of
     * LIMIT.
     */
    DISPLAY_P3_LIMIT = 14,
    /**
     * Color space with the color primaries of SRGB, the transfer characteristics of SRGB, and the color range of LIMIT.
     */
    SRGB_LIMIT = 15,
    /**
     * Color space with the color primaries of BT.709, the transfer characteristics of BT.709, and the color range of
     * LIMIT.
     */
    BT709_LIMIT = 16,
    /**
     * Color space with the color primaries of BT.601_P, the transfer characteristics of BT.709, and the color range of
     * LIMIT.
     */
    BT601_EBU_LIMIT = 17,
    /**
     * Color space with the color primaries of BT.601_N, the transfer characteristics of BT.709, and the color range of
     * LIMIT.
     */
    BT601_SMPTE_C_LIMIT = 18,
    /**
     * Color space with the color primaries of BT.2020, the transfer characteristics of HLG, and the color range of
     * LIMIT.
     */
    BT2020_HLG_LIMIT = 19,
    /**
     * Color space with the color primaries of BT.2020, the transfer characteristics of PQ, and the color range of
     * LIMIT.
     */
    BT2020_PQ_LIMIT = 20,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of HLG, and the color range of
     * LIMIT.
     */
    P3_HLG_LIMIT = 21,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of PQ, and the color range of LIMIT.
     */
    P3_PQ_LIMIT = 22,
    /**
     * Color space with the color primaries of P3_D65 and the transfer characteristic of LINEAR.
     */
    LINEAR_P3 = 23,
    /**
     * Color space with the color primaries of SRGB and the transfer characteristic of LINEAR.
     */
    LINEAR_SRGB = 24,
    /**
     * Color space with the color primaries of BT.709 and the transfer characteristic of LINEAR.
     */
    LINEAR_BT709 = LINEAR_SRGB,
    /**
     * Color space with the color primaries of BT.2020 and the transfer characteristic of LINEAR.
     */
    LINEAR_BT2020 = 25,
    /**
     * Color space with the color primaries of SRGB, the transfer characteristics of SRGB, and the color range of Full.
     */
    DISPLAY_SRGB = SRGB,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of SRGB, and the color range of
     * Full.
     */
    DISPLAY_P3_SRGB = DISPLAY_P3,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of HLG, and the color range of Full.
     */
    DISPLAY_P3_HLG = P3_HLG,
    /**
     * Color space with the color primaries of P3_D65, the transfer characteristics of PQ, and the color range of Full.
     */
    DISPLAY_P3_PQ = P3_PQ,
    /**
     * Color space with the color primaries of BT2020, the transfer characteristics of PRIV_LOG, and the color range of
     * Full.
     * @since 26.0.0
     */
    BT2020_LOG_FULL = 27,
    /**
     * Color space with the color primaries of BT2020, the transfer characteristics of PRIV_LOG, and the color range of
     * LIMIT.
     * @since 26.0.0
     */
    BT2020_LOG_LIMIT = 28,
    /**
     * Custom color space.
     */
    CUSTOM = 5,
} ColorSpaceName;

/**
 * @brief Provides the declaration for the color primary structure, which is used to store the coordinates of the red,
 * green, and blue primary colors and white point in the color space.
 *
 * @since 13
 */
typedef struct {
    /**
     * X-coordinate of the red color.
     */
    float rX;
    /**
     * Y-coordinate of the red color.
     */
    float rY;
    /**
     * X-coordinate of the green color.
     */
    float gX;
    /**
     * Y-coordinate of the green color.
     */
    float gY;
    /**
     * X-coordinate of the blue color.
     */
    float bX;
    /**
     * Y-coordinate of the blue color.
     */
    float bY;
    /**
     * X-coordinate of the white point.
     */
    float wX;
    /**
     * Y-coordinate of the white point.
     */
    float wY;
} ColorSpacePrimaries;

/**
 * @brief Provides a white point array structure. The white point is the coordinate that represents white in the
 * current color space.
 *
 * @since 13
 */
typedef struct {
    /** Indicates white point return array */
    float arr[2];
} WhitePointArray;

/**
 * @brief Creates an **OH_NativeColorSpaceManager** instance based on a color space name.
 * <br>A new **OH_NativeColorSpaceManager** instance is created each time this function is called.
 *
 * @param colorSpaceName Color space name of the created {@link OH_NativeColorSpaceManager} instance.
 * @return Returns a pointer to the {@link OH_NativeColorSpaceManager} instance. If the memory is insufficient, the **
 *     OH_NativeColorSpaceManager** instance fails to be created.
 * @since 13
 * @version 1.0
 */
OH_NativeColorSpaceManager* OH_NativeColorSpaceManager_CreateFromName(ColorSpaceName colorSpaceName)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Creates an **OH_NativeColorSpaceManager** instance based on the color primaries and gamma value.
 * <br>A new **OH_NativeColorSpaceManager** instance is created each time this function is called.
 *
 * @param primaries Primary color of the created {@link OH_NativeColorSpaceManager} instance.
 * @param gamma Gamma value of the created {@link OH_NativeColorSpaceManager} instance. The gamma value is a floating
 *     point number used to correct the brightness range.
 *     <br>Gamma values are usually positive. Negative values brighten dark areas and dim bright areas. A gamma value
 *     of **1.0** represents a linear color space.
 * @return Returns a pointer to the {@link OH_NativeColorSpaceManager} instance.
 *     <br>If the memory is insufficient, the **OH_NativeColorSpaceManager** instance fails to be created.
 * @since 13
 * @version 1.0
 */
OH_NativeColorSpaceManager* OH_NativeColorSpaceManager_CreateFromPrimariesAndGamma(
    ColorSpacePrimaries primaries, float gamma)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Destroys an **OH_NativeColorSpaceManager** instance. When the OH_NativeColorSpaceManager instance is no
 * longer needed, you need to call this function to destroy the instance to release the memory.
 *
 * @param nativeColorSpaceManager Pointer to an **OH_NativeColorSpaceManager** instance.
 * @since 13
 * @version 1.0
 */
void OH_NativeColorSpaceManager_Destroy(OH_NativeColorSpaceManager* nativeColorSpaceManager)
__attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the color space name.
 *
 * @param nativeColorSpaceManager Pointer to an **OH_NativeColorSpaceManager** instance.
 * @return Value corresponding to the color space enum {@link ColorSpaceName}. A return value of 0 indicates that the
 *     API operation failed. Possible failure cause: the nativeColorSpaceManager parameter is a null pointer.
 *     Suggestion: check whether the parameter is a valid pointer.
 * @since 13
 * @version 1.0
 */
int OH_NativeColorSpaceManager_GetColorSpaceName(
    OH_NativeColorSpaceManager* nativeColorSpaceManager)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the white points.
 *
 * @param nativeColorSpaceManager Pointer to an **OH_NativeColorSpaceManager** instance.
 * @return Return value is a float array. Return value <0.0, 0.0> indicates that the API operation failed, and other
 *     return values indicate that the operation is successful. Possible failure cause: The nativeColorSpaceManager
 *     parameter is a null pointer. Suggestion: Check whether the parameter is a valid pointer.
 * @since 13
 * @version 1.0
 */
WhitePointArray OH_NativeColorSpaceManager_GetWhitePoint(
    OH_NativeColorSpaceManager* nativeColorSpaceManager)
    __attribute__((__availability__(ohos, introduced=13.0.0)));

/**
 * @brief Obtains the gamma value.
 *
 * @param nativeColorSpaceManager Pointer to an **OH_NativeColorSpaceManager** instance.
 * @return Value of the float type. 0.0 indicates that the API operation failed, and other return values indicate
 *     success. Possible failure cause: The nativeColorSpaceManager parameter is a null pointer. Suggestion: Check
 *     whether the parameter is a valid pointer.
 * @since 13
 * @version 1.0
 */
float OH_NativeColorSpaceManager_GetGamma(OH_NativeColorSpaceManager* nativeColorSpaceManager)
__attribute__((__availability__(ohos, introduced=13.0.0)));

#ifdef __cplusplus
}
#endif

/** @} */
#endif