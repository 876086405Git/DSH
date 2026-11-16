#pragma once
#include "lifecycle_snapshot.h"

// Call once in the Node runner, before node::Start. Not an Ark NAPI module.
void RegisterPublicationBinding();

// An embedded runner can bind its linked host on each new engine thread.
void BindPublicationHost(DshReadHostLifecycleV1 read);
