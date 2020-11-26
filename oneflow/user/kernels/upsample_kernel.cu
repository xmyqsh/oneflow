/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/kernel/new_kernel_util.h"
#include "oneflow/core/common/nd_index_offset_helper.h"
#include "oneflow/core/kernel/kernel_util.cuh"

namespace oneflow {

namespace {

__host__ __device__ __forceinline__ int64_t SafeIdx(const int64_t idx, const int64_t upper) {
  return max(min(idx, upper - 1), static_cast<int64_t>(0));
}

__device__ int64_t GetNearestInputIndex(const int64_t out_dim_idx, const float scale,
                                        const int64_t in_dim_size) {
  return SafeIdx(static_cast<int64_t>(floorf((static_cast<float>(out_dim_idx) + 0.5f) * scale)),
                 in_dim_size);
}

template<typename T>
__global__ void UpsampleNearestForward(const int64_t elem_cnt, const T* in_dptr,
                                       NdIndexOffsetHelper<int64_t, 4> in_helper,
                                       NdIndexOffsetHelper<int64_t, 4> out_helper,
                                       const int64_t in_height, const int64_t in_width,
                                       const float scale_h, const float scale_w, T* out_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    out_helper.OffsetToNdIndex(index, n, c, h, w);
    const int64_t in_h = GetNearestInputIndex(h, scale_h, in_height);
    const int64_t in_w = GetNearestInputIndex(w, scale_w, in_width);
    out_dptr[index] = in_dptr[in_helper.NdIndexToOffset(n, c, in_h, in_w)];
  }
}

template<typename T>
__global__ void UpsampleNearestBackward(const int64_t elem_cnt, const T* dy_dptr,
                                        NdIndexOffsetHelper<int64_t, 4> dy_helper,
                                        NdIndexOffsetHelper<int64_t, 4> dx_helper,
                                        const int64_t dx_height, const int64_t dx_width,
                                        const float scale_h, const float scale_w, T* dx_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    dy_helper.OffsetToNdIndex(index, n, c, h, w);
    const int64_t dx_h = GetNearestInputIndex(h, scale_h, dx_height);
    const int64_t dx_w = GetNearestInputIndex(w, scale_w, dx_width);
    gpu_atomic_add(dx_dptr + dx_helper.NdIndexToOffset(n, c, dx_h, dx_w), dy_dptr[index]);
  }
}

template<typename T>
__host__ T GetAreaPixelScale(const int64_t input_size, const int64_t output_size, bool align_corners, const T scale) {
/* When the scales are inferred from the input and output sizes,
 * we view each pixel as an area, idx + 0.5 as its center index.
 * Here is an example formula in 1D case.
 * if align_corners: center of two corner pixel areas are preserved,
 *     (0.5, 0.5) -> (0.5, 0.5),
 *     (input_size - 0.5, 0.5) -> (output_size - 0.5)
 *     scale = (input_size - 0.5 - 0.5) / (output_size - 0.5 - 0.5)
 *     src_index + 0.5 - 0.5 = scale * (dst_index + 0.5 - 0.5)
 * if not align_corners: the whole range is scaled accordingly
 *     scale = input_size / output_size
 *     src_idx + 0.5 = scale * (dst_index + 0.5)
 */
  return align_corners ? static_cast<T>(input_size - 1) / (output_size - 1) :
                         (scale > 0. ? 1.0 / scale : static_cast<T>(input_size) / output_size);
}

template<typename T>
__device__ T GetAreaPixelSourceIndex(const T scale, const int64_t dst_index, bool align_corners, bool cubic) {
  if (align_corners) {
    return scale * static_cast<T>(dst_index);
  } else {
    T src_index = (static_cast<T>(dst_index) + 0.5f) * scale - 0.5f;
    return (!cubic && src_index < 0) ? 0 : src_index;
  }
}

template<typename T>
struct BilinearParam {
  int64_t top_h_index;
  int64_t bottom_h_index;
  int64_t left_w_index;
  int64_t right_w_index;
  T w_lerp;
  T h_lerp;
};

template<typename T>
__device__ void GetBilinearParam(const bool align_corners, const int64_t h, const int64_t w,
                                 const int64_t in_height, const int64_t in_width,
                                 const T scale_h, const T scale_w, BilinearParam<T>* params) {
  const T in_h = GetAreaPixelSourceIndex(scale_h, h, align_corners, /*cubic=*/false);
  const T in_w = GetAreaPixelSourceIndex(scale_w, w, align_corners, /*cubic=*/false);
  params->top_h_index = in_h > 0.0 ? floorf(in_h) : 0;
  params->bottom_h_index = (in_h < in_height - 1) ? ceilf(in_h) : in_height - 1;
  params->h_lerp = in_h - floorf(in_h);
  params->left_w_index = in_w > 0.0 ? floorf(in_w) : 0;
  params->right_w_index = (in_w < in_width - 1) ? ceilf(in_w) : in_width - 1;
  params->w_lerp = in_w - floorf(in_w);
}

template<typename T>
__global__ void UpsampleBilinearForward(const int64_t elem_cnt, const T* in_dptr,
                                        NdIndexOffsetHelper<int64_t, 4> in_helper,
                                        NdIndexOffsetHelper<int64_t, 4> out_helper,
                                        const int64_t in_height, const int64_t in_width,
                                        const T scale_h, const T scale_w,
                                        const bool align_corners, T* out_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    out_helper.OffsetToNdIndex(index, n, c, h, w);
    BilinearParam<T> params;
    GetBilinearParam(align_corners, h, w, in_height, in_width, scale_h, scale_w, &params);
    const int64_t top_offset = in_helper.NdIndexToOffset(n, c, params.top_h_index, 0);
    const int64_t bottom_offset = in_helper.NdIndexToOffset(n, c, params.bottom_h_index, 0);
    const T top_left = in_dptr[top_offset + params.left_w_index];
    const T top_right = in_dptr[top_offset + params.right_w_index];
    const T bottom_left = in_dptr[bottom_offset + params.left_w_index];
    const T bottom_right = in_dptr[bottom_offset + params.right_w_index];
    const T top = top_left + (top_right - top_left) * params.w_lerp;
    const T bottom = bottom_left + (bottom_right - bottom_left) * params.w_lerp;
    out_dptr[index] = top + (bottom - top) * params.h_lerp;
  }
}

template<typename T>
__global__ void UpsampleBilinearBackward(const int64_t elem_cnt, const T* dy_dptr,
                                         NdIndexOffsetHelper<int64_t, 4> dy_helper,
                                         NdIndexOffsetHelper<int64_t, 4> dx_helper,
                                         const int64_t dx_height, const int64_t dx_width,
                                         const T scale_h, const T scale_w,
                                         const bool align_corners, T* dx_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    dy_helper.OffsetToNdIndex(index, n, c, h, w);
    BilinearParam<T> params;
    GetBilinearParam(align_corners, h, w, dx_height, dx_width, scale_h, scale_w, &params);
    const int64_t top_offset = dx_helper.NdIndexToOffset(n, c, params.top_h_index, 0);
    const int64_t bottom_offset = dx_helper.NdIndexToOffset(n, c, params.bottom_h_index, 0);
    const T dy = dy_dptr[index];
    const T dbottom = params.h_lerp * dy;
    T* dx_dptr_bottom_offset = dx_dptr + bottom_offset;
    gpu_atomic_add(dx_dptr_bottom_offset + params.left_w_index,
                   static_cast<T>((1 - params.w_lerp) * dbottom));
    gpu_atomic_add(dx_dptr_bottom_offset + params.right_w_index,
                   static_cast<T>(params.w_lerp * dbottom));
    const T dtop = dy - dbottom;
    T* dx_dptr_top_offset = dx_dptr + top_offset;
    gpu_atomic_add(dx_dptr_top_offset + params.left_w_index,
                   static_cast<T>((1 - params.w_lerp) * dtop));
    gpu_atomic_add(dx_dptr_top_offset + params.right_w_index, static_cast<T>(params.w_lerp * dtop));
  }
}

template<typename T>
struct BicubicParam {
  int64_t left_w_index;
  int64_t top_h_index;
  T x_coeffs[4];
  T y_coeffs[4];
};

// Based on
// https://en.wikipedia.org/wiki/Bicubic_interpolation#Bicubic_convolution_algorithm
template<typename T>
__device__ __forceinline__ static T cubic_convolution1(const T x, const T A) {
  return ((A + 2) * x - (A + 3)) * x * x + 1;
}

template<typename T>
__device__ __forceinline__ static T cubic_convolution2(const T x, const T A) {
  return ((A * x - 5 * A) * x + 8 * A) * x - 4 * A;
}

template<typename T>
__device__ void GetCubicUpsamplingCoefficients(const T lerp, T coeffs[4]) {
  T A = -0.75;

  T x1 = lerp;
  coeffs[0] = cubic_convolution2(x1 + static_cast<T>(1.0), A);
  coeffs[1] = cubic_convolution1(x1, A);

  // opposite coefficients
  T x2 = 1.0 - lerp;
  coeffs[2] = cubic_convolution1(x2, A);
  coeffs[3] = cubic_convolution2(x2 + static_cast<T>(1.0), A);
}

template<typename T>
__device__ T cubic_interp1d(const T x0, const T x1, const T x2, const T x3,
                            const T coeffs[4]) {
  return x0 * coeffs[0] + x1 * coeffs[1] + x2 * coeffs[2] + x3 * coeffs[3];
}

template<typename T>
__device__ void GetBicubicParam(const bool align_corners, const int64_t h, const int64_t w,
                                const int64_t in_height, const int64_t in_width,
                                const T scale_h, const T scale_w, BicubicParam<T>* params) {
  const T in_h = GetAreaPixelSourceIndex(scale_h, h, align_corners, /*cubic=*/true);
  const T in_w = GetAreaPixelSourceIndex(scale_w, w, align_corners, /*cubic=*/true);
  params->top_h_index = static_cast<int64_t>(floorf(in_h));
  params->left_w_index = static_cast<int64_t>(floorf(in_w));
  T h_lerp = in_h - params->top_h_index;
  T w_lerp = in_w - params->left_w_index;
  GetCubicUpsamplingCoefficients(h_lerp, params->y_coeffs);
  GetCubicUpsamplingCoefficients(w_lerp, params->x_coeffs);
}

template<typename T>
__global__ void
__launch_bounds__(1024)
UpsampleBicubicForward(const int64_t elem_cnt, const T* in_dptr,
                       NdIndexOffsetHelper<int64_t, 4> in_helper,
                       NdIndexOffsetHelper<int64_t, 4> out_helper,
                       const int64_t in_height, const int64_t in_width,
                       const T scale_h, const T scale_w,
                       const bool align_corners, T* out_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    out_helper.OffsetToNdIndex(index, n, c, h, w);
    BicubicParam<T> params;
    GetBicubicParam(align_corners, h, w, in_height, in_width, scale_h, scale_w, &params);
    T coefficients[4];
    for (int k = 0; k != 4; ++k) {
      const int64_t top_offset = in_helper.NdIndexToOffset(n, c, SafeIdx(params.top_h_index - 1 + k, in_height));
      coefficients[k] = cubic_interp1d(
          in_dptr[top_offset + SafeIdx(params.left_w_index - 1, in_width)],
          in_dptr[top_offset + SafeIdx(params.left_w_index + 0, in_width)],
          in_dptr[top_offset + SafeIdx(params.left_w_index + 1, in_width)],
          in_dptr[top_offset + SafeIdx(params.left_w_index + 2, in_width)],
          params.x_coeffs);
    }
    out_dptr[index] = cubic_interp1d(
        coefficients[0],
        coefficients[1],
        coefficients[2],
        coefficients[3],
        params.y_coeffs);
  }
}

template<typename T>
__global__ void
__launch_bounds__(1024)
UpsampleBicubicBackward(const int64_t elem_cnt, const T* dy_dptr,
                        NdIndexOffsetHelper<int64_t, 4> dy_helper,
                        NdIndexOffsetHelper<int64_t, 4> dx_helper,
                        const int64_t dx_height, const int64_t dx_width,
                        const T scale_h, const T scale_w,
                        const bool align_corners, T* dx_dptr) {
  CUDA_1D_KERNEL_LOOP(index, elem_cnt) {
    int64_t n, c, h, w;
    dy_helper.OffsetToNdIndex(index, n, c, h, w);
    BicubicParam<T> params;
    GetBicubicParam(align_corners, h, w, dx_height, dx_width, scale_h, scale_w, &params);
    const T out_value = dy_dptr[index];
    for (int i = 0; i != 4; ++i) {
      for (int j = 0; j != 4; ++j) {
        gpu_atomic_add(dx_dptr + dx_helper.NdIndexToOffset(n, c,
                               SafeIdx(params.top_h_index - 1 + i, dx_height),
                               SafeIdx(params.left_w_index - 1 + j, dx_width)),
                       out_value * static_cast<T>(params.y_coeffs[i]) * static_cast<T>(params.x_coeffs[j]));
      }
    }
  }
}

}  // namespace

template<typename T>
class UpsampleNearestGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleNearestGPUKernel() = default;
  ~UpsampleNearestGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* x_blob = ctx->Tensor4ArgNameAndIndex("x", 0);
    user_op::Tensor* y_blob = ctx->Tensor4ArgNameAndIndex("y", 0);
    const float height_scale = ctx->Attr<float>("height_scale");
    const float width_scale = ctx->Attr<float>("width_scale");
    const int64_t elem_cnt = y_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> in_helper(x_blob->shape().At(0), x_blob->shape().At(1),
                                              x_blob->shape().At(2), x_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> out_helper(y_blob->shape().At(0), y_blob->shape().At(1),
                                               y_blob->shape().At(2), y_blob->shape().At(3));

    RUN_CUDA_KERNEL((UpsampleNearestForward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    x_blob->dptr<T>(), in_helper, out_helper, x_blob->shape().At(2),
                    x_blob->shape().At(3), 1.f / height_scale, 1.f / width_scale,
                    y_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename T>
class UpsampleNearestGradGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleNearestGradGPUKernel() = default;
  ~UpsampleNearestGradGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    user_op::Tensor* dx_blob = ctx->Tensor4ArgNameAndIndex("dx", 0);
    if (dx_blob == nullptr) { return; }
    Memset<DeviceType::kGPU>(ctx->device_ctx(), dx_blob->mut_dptr<T>(), 0,
                             dx_blob->shape().elem_cnt() * sizeof(T));
    const user_op::Tensor* dy_blob = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const float height_scale = ctx->Attr<float>("height_scale");
    const float width_scale = ctx->Attr<float>("width_scale");
    const int64_t elem_cnt = dy_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> dy_helper(dy_blob->shape().At(0), dy_blob->shape().At(1),
                                              dy_blob->shape().At(2), dy_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> dx_helper(dx_blob->shape().At(0), dx_blob->shape().At(1),
                                              dx_blob->shape().At(2), dx_blob->shape().At(3));
    RUN_CUDA_KERNEL((UpsampleNearestBackward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    dy_blob->dptr<T>(), dy_helper, dx_helper, dx_blob->shape().At(2),
                    dx_blob->shape().At(3), 1.f / height_scale, 1.f / width_scale,
                    dx_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_UPSAMPLE_NEAREST_GPU_KERNEL(dtype)                                      \
  REGISTER_USER_KERNEL("upsample")                                                       \
      .SetCreateFn<UpsampleNearestGPUKernel<dtype>>()                                    \
      .SetIsMatchedHob(                                                                  \
          (user_op::HobDeviceTag() == "gpu")                                             \
          & (user_op::HobDataType("y", 0) == GetDataType<dtype>::value)                  \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("nearest"))); \
  REGISTER_USER_KERNEL("upsample_grad")                                                  \
      .SetCreateFn<UpsampleNearestGradGPUKernel<dtype>>()                                \
      .SetIsMatchedHob(                                                                  \
          (user_op::HobDeviceTag() == "gpu")                                             \
          & (user_op::HobDataType("dx", 0) == GetDataType<dtype>::value)                 \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("nearest")));

REGISTER_UPSAMPLE_NEAREST_GPU_KERNEL(float)
REGISTER_UPSAMPLE_NEAREST_GPU_KERNEL(double)

template<typename T>
class UpsampleBilinearGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleBilinearGPUKernel() = default;
  ~UpsampleBilinearGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* x_blob = ctx->Tensor4ArgNameAndIndex("x", 0);
    user_op::Tensor* y_blob = ctx->Tensor4ArgNameAndIndex("y", 0);
    const T height_scale = static_cast<T>(ctx->Attr<float>("height_scale"));
    const T width_scale = static_cast<T>(ctx->Attr<float>("width_scale"));
    const bool align_corners = ctx->Attr<bool>("align_corners");
    const int64_t elem_cnt = y_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> in_helper(x_blob->shape().At(0), x_blob->shape().At(1),
                                              x_blob->shape().At(2), x_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> out_helper(y_blob->shape().At(0), y_blob->shape().At(1),
                                               y_blob->shape().At(2), y_blob->shape().At(3));

    const int64_t in_height = x_blob->shape().At(2);
    const int64_t in_width = x_blob->shape().At(3);
    const int64_t out_height = y_blob->shape().At(2);
    const int64_t out_width = y_blob->shape().At(3);
    const T scale_height = GetAreaPixelScale(in_height, out_height, align_corners, height_scale);
    const T scale_width = GetAreaPixelScale(in_width, out_width, align_corners, width_scale);
    RUN_CUDA_KERNEL((UpsampleBilinearForward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    x_blob->dptr<T>(), in_helper, out_helper, in_height,
                    in_width, scale_height, scale_width,
                    align_corners, y_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename T>
class UpsampleBilinearGradGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleBilinearGradGPUKernel() = default;
  ~UpsampleBilinearGradGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    user_op::Tensor* dx_blob = ctx->Tensor4ArgNameAndIndex("dx", 0);
    if (dx_blob == nullptr) { return; }
    Memset<DeviceType::kGPU>(ctx->device_ctx(), dx_blob->mut_dptr<T>(), 0,
                             dx_blob->shape().elem_cnt() * sizeof(T));
    const user_op::Tensor* dy_blob = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const T height_scale = static_cast<T>(ctx->Attr<float>("height_scale"));
    const T width_scale = static_cast<T>(ctx->Attr<float>("width_scale"));
    const bool align_corners = ctx->Attr<bool>("align_corners");
    const int64_t elem_cnt = dy_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> dy_helper(dy_blob->shape().At(0), dy_blob->shape().At(1),
                                              dy_blob->shape().At(2), dy_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> dx_helper(dx_blob->shape().At(0), dx_blob->shape().At(1),
                                              dx_blob->shape().At(2), dx_blob->shape().At(3));

    const int64_t in_height = dx_blob->shape().At(2);
    const int64_t in_width = dx_blob->shape().At(3);
    const int64_t out_height = dy_blob->shape().At(2);
    const int64_t out_width = dy_blob->shape().At(3);
    const T scale_height = GetAreaPixelScale(in_height, out_height, align_corners, height_scale);
    const T scale_width = GetAreaPixelScale(in_width, out_width, align_corners, width_scale);
    RUN_CUDA_KERNEL((UpsampleBilinearBackward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    dy_blob->dptr<T>(), dy_helper, dx_helper, in_height,
                    in_width, scale_height, scale_width,
                    align_corners, dx_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_UPSAMPLE_BILINEAR_GPU_KERNEL(dtype)                                      \
  REGISTER_USER_KERNEL("upsample")                                                        \
      .SetCreateFn<UpsampleBilinearGPUKernel<dtype>>()                                    \
      .SetIsMatchedHob(                                                                   \
          (user_op::HobDeviceTag() == "gpu")                                              \
          & (user_op::HobDataType("y", 0) == GetDataType<dtype>::value)                   \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("bilinear"))); \
  REGISTER_USER_KERNEL("upsample_grad")                                                   \
      .SetCreateFn<UpsampleBilinearGradGPUKernel<dtype>>()                                \
      .SetIsMatchedHob(                                                                   \
          (user_op::HobDeviceTag() == "gpu")                                              \
          & (user_op::HobDataType("dx", 0) == GetDataType<dtype>::value)                  \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("bilinear")));

REGISTER_UPSAMPLE_BILINEAR_GPU_KERNEL(float)
REGISTER_UPSAMPLE_BILINEAR_GPU_KERNEL(double)

template<typename T>
class UpsampleBicubicGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleBicubicGPUKernel() = default;
  ~UpsampleBicubicGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* x_blob = ctx->Tensor4ArgNameAndIndex("x", 0);
    user_op::Tensor* y_blob = ctx->Tensor4ArgNameAndIndex("y", 0);
    const T height_scale = static_cast<T>(ctx->Attr<float>("height_scale"));
    const T width_scale = static_cast<T>(ctx->Attr<float>("width_scale"));
    const bool align_corners = ctx->Attr<bool>("align_corners");
    const int64_t elem_cnt = y_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> in_helper(x_blob->shape().At(0), x_blob->shape().At(1),
                                              x_blob->shape().At(2), x_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> out_helper(y_blob->shape().At(0), y_blob->shape().At(1),
                                               y_blob->shape().At(2), y_blob->shape().At(3));

    const int64_t in_height = x_blob->shape().At(2);
    const int64_t in_width = x_blob->shape().At(3);
    const int64_t out_height = y_blob->shape().At(2);
    const int64_t out_width = y_blob->shape().At(3);
    const T scale_height = GetAreaPixelScale(in_height, out_height, align_corners, height_scale);
    const T scale_width = GetAreaPixelScale(in_width, out_width, align_corners, width_scale);
    RUN_CUDA_KERNEL((UpsampleBicubicForward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    x_blob->dptr<T>(), in_helper, out_helper, in_height,
                    in_width, scale_height, scale_width,
                    align_corners, y_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename T>
class UpsampleBicubicGradGPUKernel final : public user_op::OpKernel {
 public:
  UpsampleBicubicGradGPUKernel() = default;
  ~UpsampleBicubicGradGPUKernel() = default;

 private:
  void Compute(user_op::KernelComputeContext* ctx) const override {
    user_op::Tensor* dx_blob = ctx->Tensor4ArgNameAndIndex("dx", 0);
    if (dx_blob == nullptr) { return; }
    Memset<DeviceType::kGPU>(ctx->device_ctx(), dx_blob->mut_dptr<T>(), 0,
                             dx_blob->shape().elem_cnt() * sizeof(T));
    const user_op::Tensor* dy_blob = ctx->Tensor4ArgNameAndIndex("dy", 0);
    const T height_scale = static_cast<T>(ctx->Attr<float>("height_scale"));
    const T width_scale = static_cast<T>(ctx->Attr<float>("width_scale"));
    const bool align_corners = ctx->Attr<bool>("align_corners");
    const int64_t elem_cnt = dy_blob->shape().elem_cnt();
    NdIndexOffsetHelper<int64_t, 4> dy_helper(dy_blob->shape().At(0), dy_blob->shape().At(1),
                                              dy_blob->shape().At(2), dy_blob->shape().At(3));
    NdIndexOffsetHelper<int64_t, 4> dx_helper(dx_blob->shape().At(0), dx_blob->shape().At(1),
                                              dx_blob->shape().At(2), dx_blob->shape().At(3));

    const int64_t in_height = dx_blob->shape().At(2);
    const int64_t in_width = dx_blob->shape().At(3);
    const int64_t out_height = dy_blob->shape().At(2);
    const int64_t out_width = dy_blob->shape().At(3);
    const T scale_height = GetAreaPixelScale(in_height, out_height, align_corners, height_scale);
    const T scale_width = GetAreaPixelScale(in_width, out_width, align_corners, width_scale);
    RUN_CUDA_KERNEL((UpsampleBicubicBackward<T>), ctx->device_ctx(), elem_cnt, elem_cnt,
                    dy_blob->dptr<T>(), dy_helper, dx_helper, in_height,
                    in_width, scale_height, scale_width,
                    align_corners, dx_blob->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_UPSAMPLE_BICUBIC_GPU_KERNEL(dtype)                                      \
  REGISTER_USER_KERNEL("upsample")                                                       \
      .SetCreateFn<UpsampleBicubicGPUKernel<dtype>>()                                    \
      .SetIsMatchedHob(                                                                  \
          (user_op::HobDeviceTag() == "gpu")                                             \
          & (user_op::HobDataType("y", 0) == GetDataType<dtype>::value)                  \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("bicubic"))); \
  REGISTER_USER_KERNEL("upsample_grad")                                                  \
      .SetCreateFn<UpsampleBicubicGradGPUKernel<dtype>>()                                \
      .SetIsMatchedHob(                                                                  \
          (user_op::HobDeviceTag() == "gpu")                                             \
          & (user_op::HobDataType("dx", 0) == GetDataType<dtype>::value)                 \
          & (user_op::HobAttr<std::string>("interpolation") == std::string("bicubic")));

REGISTER_UPSAMPLE_BICUBIC_GPU_KERNEL(float)
REGISTER_UPSAMPLE_BICUBIC_GPU_KERNEL(double)

}  // namespace oneflow
