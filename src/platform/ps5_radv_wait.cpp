// PS5: shorter sleeps in RADV's GPU wait.
//
// The PS5 winsys waits for a submission by polling a memory marker: it spins
// for 1.5 ms, then sleeps 1 ms between polls (radv_ps5_queue_wait_seq in the
// Mesa fork's radv_ps5_winsys.c). A wait that outlasts the spin therefore ends
// up to a millisecond after the GPU is done. The GPU command thread waits like
// this several times a frame, and the game's render thread waits on it.
//
// ps5/link-title.sh links with --wrap=radv_ps5_sleep_us, so the winsys's calls
// (in other objects than the definition) land here. Sleeps of 1 ms or more are
// cut to FABLE2_RADV_WAIT_US microseconds (default 100; 0 = sched_yield).
// Only this title is affected; the shared RADV build is unchanged.

#include <sched.h>

#include <cstdlib>

extern "C" void __real_radv_ps5_sleep_us(unsigned microseconds);

namespace {

unsigned WaitSleepUs() {
  static const unsigned value = [] {
    const char* env = std::getenv("FABLE2_RADV_WAIT_US");
    if (!env || !*env) {
      return 100u;
    }
    return unsigned(std::strtoul(env, nullptr, 10));
  }();
  return value;
}

}  // namespace

extern "C" void __wrap_radv_ps5_sleep_us(unsigned microseconds) {
  if (microseconds >= 1000) {
    microseconds = WaitSleepUs();
    if (microseconds == 0) {
      sched_yield();
      return;
    }
  }
  __real_radv_ps5_sleep_us(microseconds);
}
