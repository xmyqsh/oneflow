#ifndef ONEFLOW_CORE_OPERATOR_KEEP_HEADER_ONLY_OP_H_
#define ONEFLOW_CORE_OPERATOR_KEEP_HEADER_ONLY_OP_H_

#include "oneflow/core/operator/identity_op.h"
#include "oneflow/core/graph/logical_node.h"

namespace oneflow {

class KeepHeaderOnlyOp final : public Operator {
 public:
  OF_DISALLOW_COPY_AND_MOVE(KeepHeaderOnlyOp);
  KeepHeaderOnlyOp() = default;
  ~KeepHeaderOnlyOp() override = default;

  void InitFromOpConf() override;

  const PbMessage& GetCustomizedConf() const override { return op_conf().keep_header_only_conf(); }
  Maybe<void> InferBlobDescs(std::function<BlobDesc*(const std::string&)> GetBlobDesc4BnInOp,
                             const ParallelContext* parallel_ctx) const override;

 private:
  Maybe<void> InferBatchAxis(
      std::function<OptInt64*(const std::string&)> BatchAxis4BnInOp) const override;

  Maybe<void> GetSbpSignatures(
      const std::function<Maybe<const BlobDesc*>(const std::string&)>& LogicalBlobDesc4Ibn,
      SbpSignatureList* sbp_sig_list) const override;
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_OPERATOR_KEEP_HEADER_ONLY_OP_H_