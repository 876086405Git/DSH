#pragma once

// Called once before Node initialization. Secrets are never serialized to disk,
// argv, environment, stdout or state JSON.
void RegisterPhoneBinding();
extern "C" int dsh_ios_phone_arm(const char* run_id, const char* token);
extern "C" void dsh_ios_phone_clear(const char* run_id);
