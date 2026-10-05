#include "AethelnCombatTestAbilities.h"

namespace AethelnCombatTestTags
{
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_LongRunning, "Ability.Test.LongRunning", "Test-only identity of UAethelnLongRunningTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_Probe, "Ability.Test.Probe", "Test-only identity of UAethelnSeamProbeTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Ability_Test_Triggered, "Ability.Test.Triggered", "Test-only identity of UAethelnTriggeredTestAbility");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Trigger, "Test.Trigger", "Test-only gameplay event that UAethelnTriggeredTestAbility responds to");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_ProbeActive, "Test.ProbeActive", "Test-only state tag held while the seam probe is active");
	UE_DEFINE_GAMEPLAY_TAG_COMMENT(Test_Blocking, "Test.Blocking", "Test-only tag that blocks the seam probe");
}
