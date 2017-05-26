#include "thread/thread_manager.h"
#include "thread/gpu_thread.h"
#include "thread/cpu_thread.h"
#include  "common/job_desc.h"
#include <utility>

namespace oneflow {

ThreadMgr::~ThreadMgr() {
  JoinAllThreads();
}

Thread* ThreadMgr::GetThrd(uint64_t thrd_loc_id) {
  return threads_.at(thrd_loc_id).get();
}

void ThreadMgr::JoinAllThreads() {
  for (const std::unique_ptr<Thread>& thrd : threads_) {
    thrd->Join();
  }
}

void ThreadMgr::Reserve(size_t n) {
  threads_.reserve(n);
}

ThreadMgr::ThreadMgr() {
  // device thread - device_num_per_machine
  uint64_t dev_num_per_machine = 
      JobDesc::Singleton().resource().device_num_per_machine();
  uint64_t device_type = JobDesc::Singleton().resource().device_type();
  for (uint64_t dev_phy_id = 0; dev_phy_id < dev_num_per_machine; ++dev_phy_id){
    if (device_type == kGPU) {
      threads_.push_back(std::move(of_make_unique<GpuThread>(dev_phy_id)));
    } else {
      threads_.push_back(std::move(of_make_unique<CpuThread>()));
    }
  }
  // cpu thread - for disk
  threads_.push_back(std::move(of_make_unique<CpuThread>()));
  // cpu thread - for boxing
  threads_.push_back(std::move(of_make_unique<CpuThread>()));
  // cpu thread - for commnet
  threads_.push_back(std::move(of_make_unique<CpuThread>()));
}

}  // namespace oneflow
