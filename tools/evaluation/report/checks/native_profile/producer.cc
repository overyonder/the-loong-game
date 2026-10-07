// Exercise the separately owned wire producer, without a CUDA context. Values
// are deliberate bit/count oracles, not simulated performance measurements.
#include "native_profile.h"

int main() {
  NativeMatchProfile profile;
  profile.host[static_cast<size_t>(NativeHostStage::SETUP)] = {111, 1};
  profile.host[static_cast<size_t>(NativeHostStage::CALLBACK_SUM)] = {990, 88};
  profile.host[static_cast<size_t>(NativeHostStage::SERIALIZE)] = {777, 44};
  profile.device[static_cast<size_t>(NativeDeviceStageTiming::ACTIONS_HTOD)] = {
      123, 9};
  profile.waves = 7;
  profile.decisions = 88;
  profile.copiesHtoD = 19;
  profile.bytesHtoD = 9007199254740993ULL;
  profile.copiesDtoH = 23;
  profile.bytesDtoH = 456;
  profile.print(44, true, false);
}
