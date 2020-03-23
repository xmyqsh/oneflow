#ifndef ONEFLOW_CORE_OPERATOR_AXPY_OP_H_
#define ONEFLOW_CORE_OPERATOR_AXPY_OP_H_

#include "oneflow/core/operator/operator.h"

namespace oneflow {

class AxpyOp final : public Operator {
 public:
  OF_DISALLOW_COPY_AND_MOVE(AxpyOp);
  AxpyOp() = default;
  ~AxpyOp() = default;

  void InitFromOpConf() override;
  const PbMessage& GetCustomizedConf() const override;
  Maybe<void> InferBlobDescs(std::function<BlobDesc*(const std::string&)> GetBlobDesc4BnInOp,
                             const ParallelContext* parallel_ctx) const override;

 private:
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_OPERATOR_AXPY_OP_H_