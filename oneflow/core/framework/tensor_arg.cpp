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

#include "oneflow/core/framework/tensor_arg.h"

namespace oneflow {
namespace one {

bool TensorArg::Empty() const { return partial_sum_tensors_.empty() && acc_tensor_; }

void TensorArg::Release() {
  partial_sum_tensors_.clear();
  acc_tensor_.reset();
}

void TensorArg::PushPartialTensor(const std::shared_ptr<Tensor>& partial_tensor) {
  partial_sum_tensors_.push_back(partial_tensor);
}

}  // namespace one
}  // namespace oneflow
