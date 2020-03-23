#ifndef ONEFLOW_CORE_OPERATOR_CONV_BIAS_GRAD_OP_H_
#define ONEFLOW_CORE_OPERATOR_CONV_BIAS_GRAD_OP_H_

#include "oneflow/core/operator/operator.h"

namespace oneflow {

class ConvBiasGradOp : public Operator {
 public:
  OF_DISALLOW_COPY_AND_MOVE(ConvBiasGradOp);
  ConvBiasGradOp() = default;
  ~ConvBiasGradOp() override = default;

  void InitFromOpConf() override;
  Maybe<void> InferBlobDescs(std::function<BlobDesc*(const std::string&)> GetBlobDesc4BnInOp,
                             const ParallelContext* parallel_ctx) const override;

 private:
  Maybe<void> InferBatchAxis(
      std::function<OptInt64*(const std::string&)> BatchAxis4BnInOp) const override;
  Maybe<void> GetSbpSignatures(
      const std::function<Maybe<const BlobDesc*>(const std::string&)>& LogicalBlobDesc4Ibn,
      SbpSignatureList* sbp_sig_list) const override;
  const PbMessage& GetCustomizedConf() const override;
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_OPERATOR_CONV_BIAS_GRAD_OP_H_