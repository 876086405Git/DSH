// Experiment link substitute only: keep the exact reviewed runner's argument
// checks and node::Start call, while deliberately disabling its old registration.
#include "publication_binding.h"
#include <cstdio>
void RegisterPublicationBinding() {
  std::fputs("M6_TEST_STATIC_REGISTRATION_DISABLED\n", stderr);
}
