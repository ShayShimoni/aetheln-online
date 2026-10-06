#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnActivationTypes.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnGameplayTags.h"
#include "AethelnOathscarAbilities.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "GameplayTagsManager.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"
#include <limits>

namespace AethelnOathscarAbilityTests
{
	using AethelnCombatTests::FScopedCombatTestWorld;
	using EResult = EAethelnActivationResult;

	struct FDefinition
	{
		TSubclassOf<UAethelnGameplayAbility> Class;
		FGameplayTag AbilityId;
		FGameplayTag CooldownTag;
		const TCHAR* SemanticId;
	};

	/** The canon mapping (docs/combat-and-networking-architecture.md, Initial entries). */
	TArray<FDefinition> GetDefinitions()
	{
		return {
			{ UAethelnGateStepAbility::StaticClass(), AethelnGameplayTags::Ability_Oathscar_GateStep, AethelnGameplayTags::Cooldown_Oathscar_GateStep, TEXT("order.oathscar.ability.gate_step") },
			{ UAethelnSwornRebukeAbility::StaticClass(), AethelnGameplayTags::Ability_Oathscar_SwornRebuke, AethelnGameplayTags::Cooldown_Oathscar_SwornRebuke, TEXT("order.oathscar.ability.sworn_rebuke") },
			{ UAethelnHoldTheLineAbility::StaticClass(), AethelnGameplayTags::Ability_Oathscar_HoldTheLine, AethelnGameplayTags::Cooldown_Oathscar_HoldTheLine, TEXT("order.oathscar.ability.hold_the_line") },
		};
	}

	void ExpectResult(FAutomationTestBase& Test, const FString& What, EResult Actual, EResult Expected)
	{
		const UEnum* ResultEnum = StaticEnum<EAethelnActivationResult>();
		Test.TestEqual(What, ResultEnum->GetNameStringByValue(static_cast<int64>(Actual)), ResultEnum->GetNameStringByValue(static_cast<int64>(Expected)));
	}

	/**
	 * A possessed player granted the three skeletons with the test-pinned attributes.
	 * Each test sets its own cost and cooldown on the granted instances, which the seam
	 * checks and CommitAbility spends; the fixture starts them at no cost and no cooldown.
	 */
	struct FOathscarFixture
	{
		AethelnCombatTests::FTestPlayer Player;
		TArray<UAethelnGameplayAbility*> Instances;
		TArray<FGameplayAbilitySpecHandle> Handles;
		uint32 NextSequence = 1;
		int32 CostEffects = 0;
		int32 CooldownEffects = 0;
		int32 Commits = 0;
		int32 CancelledEnds = 0;

		bool Init(FAutomationTestBase& Test, const FScopedCombatTestWorld& TestWorld, const TArray<TSubclassOf<UGameplayAbility>>& Abilities)
		{
			if (!AethelnCombatTests::SpawnTestPlayer(Test, TestWorld, Player, Abilities))
			{
				return false;
			}
			AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
			{
				return false;
			}
			Player.Controller->Possess(Pawn);
			for (const FDefinition& Definition : GetDefinitions())
			{
				const FGameplayAbilitySpec* Spec = Player.AbilitySystem->FindAbilitySpecFromClass(Definition.Class);
				UAethelnGameplayAbility* Instance = Spec != nullptr ? Cast<UAethelnGameplayAbility>(Spec->GetPrimaryInstance()) : nullptr;
				if (!Test.TestNotNull(*FString::Printf(TEXT("%s is granted with an instance"), *Definition.AbilityId.ToString()), Instance))
				{
					return false;
				}
				Instance->ProvisionalEnduranceCost = 0.0f;
				Instance->ProvisionalCooldownSeconds = 0.0f;
				Instances.Add(Instance);
				Handles.Add(Spec->Handle);
			}

			UAethelnAbilitySystemComponent& AbilitySystem = *Player.AbilitySystem;
			AbilitySystem.OnGameplayEffectAppliedDelegateToSelf.AddLambda([this](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
			{
				const UClass* EffectClass = Spec.Def != nullptr ? Spec.Def->GetClass() : nullptr;
				CostEffects += EffectClass == UAethelnEnduranceCostEffect::StaticClass() ? 1 : 0;
				CooldownEffects += EffectClass == UAethelnCooldownEffect::StaticClass() ? 1 : 0;
			});
			AbilitySystem.AbilityCommittedCallbacks.AddLambda([this](UGameplayAbility*) { ++Commits; });
			AbilitySystem.OnAbilityEnded.AddLambda([this](const FAbilityEndedData& Data) { CancelledEnds += Data.bWasCancelled ? 1 : 0; });
			return true;
		}

		bool Init(FAutomationTestBase& Test, const FScopedCombatTestWorld& TestWorld)
		{
			TArray<TSubclassOf<UGameplayAbility>> Abilities;
			for (const FDefinition& Definition : GetDefinitions())
			{
				Abilities.Add(Definition.Class);
			}
			return Init(Test, TestWorld, Abilities);
		}

		/** A Press with a fresh sequence and the granted definition's content version unless one is given. */
		EResult Submit(int32 Index, TOptional<uint32> ContentVersion = {})
		{
			const FDefinition Definition = GetDefinitions()[Index];
			FAethelnCombatActivationRequest Request;
			Request.AbilityId = Definition.AbilityId;
			Request.ContentVersion = ContentVersion.Get(Definition.Class->GetDefaultObject<UAethelnGameplayAbility>()->ContentVersion);
			Request.Sequence = NextSequence++;
			return Player.AbilitySystem->ProcessServerRequest(Request);
		}

		bool IsActive(int32 Index) const
		{
			const FGameplayAbilitySpec* Spec = Player.AbilitySystem->FindAbilitySpecFromHandle(Handles[Index]);
			return Spec != nullptr && Spec->IsActive();
		}

		float Endurance() const
		{
			return Player.AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute());
		}
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAbilitiesCostAndCooldownCommitTest,
	"Aetheln.GameCombat.Abilities.CostAndCooldownCommit",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAbilitiesCostAndCooldownCommitTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarAbilityTests;

	// The fixture outlives the world, so its delegate bindings never dangle during teardown.
	FOathscarFixture Fixture;
	FScopedCombatTestWorld TestWorld;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnAbilitySystemComponent& AbilitySystem = *Fixture.Player.AbilitySystem;

	// Test-pinned values, not tuning.
	constexpr float Cost = 4.0f;
	constexpr float CooldownSeconds = 7.0f;
	const TArray<FDefinition> Definitions = GetDefinitions();
	for (int32 Index = 0; Index < Definitions.Num(); ++Index)
	{
		const FDefinition& Definition = Definitions[Index];
		const FString Name = Definition.AbilityId.ToString();
		const FGameplayTagContainer CooldownTags(Definition.CooldownTag);
		Fixture.Instances[Index]->ProvisionalEnduranceCost = Cost;
		Fixture.Instances[Index]->ProvisionalCooldownSeconds = CooldownSeconds;
		const float EnduranceBefore = Fixture.Endurance();
		Fixture.CostEffects = 0;
		Fixture.CooldownEffects = 0;
		Fixture.Commits = 0;
		Fixture.CancelledEnds = 0;

		// The previous ability is still on its own cooldown, so acceptance here also shows the cooldowns are independent.
		ExpectResult(*this, Name + TEXT(": accepted"), Fixture.Submit(Index), EResult::Accepted);
		TestEqual(Name + TEXT(": one cost effect"), Fixture.CostEffects, 1);
		TestEqual(Name + TEXT(": Endurance spent once"), Fixture.Endurance(), EnduranceBefore - Cost);
		TestEqual(Name + TEXT(": one cooldown effect"), Fixture.CooldownEffects, 1);
		TestTrue(Name + TEXT(": the cooldown tag is granted"), AbilitySystem.HasMatchingGameplayTag(Definition.CooldownTag));
		const TArray<float> Durations = AbilitySystem.GetActiveEffectsDuration(FGameplayEffectQuery::MakeQuery_MatchAnyOwningTags(CooldownTags));
		TestEqual(Name + TEXT(": one active cooldown effect carries the tag"), Durations.Num(), 1);
		TestTrue(Name + TEXT(": the cooldown lasts the configured duration"), Durations.Num() == 1 && FMath::IsNearlyEqual(Durations[0], CooldownSeconds));
		TestEqual(Name + TEXT(": committed once, through CommitAbility"), Fixture.Commits, 1);
		TestFalse(Name + TEXT(": the activation ended"), Fixture.IsActive(Index));
		TestEqual(Name + TEXT(": it ended itself; nothing was cancelled"), Fixture.CancelledEnds, 0);

		ExpectResult(*this, Name + TEXT(": a request during the cooldown"), Fixture.Submit(Index), EResult::OnCooldown);
		TestEqual(Name + TEXT(": the cooldown rejection spends nothing"), Fixture.Endurance(), EnduranceBefore - Cost);
		TestEqual(Name + TEXT(": the cooldown rejection applies no effect"), Fixture.CostEffects + Fixture.CooldownEffects, 2);

		// No ticking in the headless world: the test removes the cooldown effect itself.
		TestEqual(Name + TEXT(": the test removes the cooldown effect"), AbilitySystem.RemoveActiveEffectsWithGrantedTags(CooldownTags), 1);
		TestFalse(Name + TEXT(": the cooldown tag is gone"), AbilitySystem.HasMatchingGameplayTag(Definition.CooldownTag));
		ExpectResult(*this, Name + TEXT(": accepted again after the cooldown"), Fixture.Submit(Index), EResult::Accepted);
		TestEqual(Name + TEXT(": the second acceptance spends once more"), Fixture.Endurance(), EnduranceBefore - 2.0f * Cost);
		TestEqual(Name + TEXT(": the second acceptance applies one more cost and cooldown"), Fixture.CostEffects + Fixture.CooldownEffects, 4);
		TestEqual(Name + TEXT(": two commits in all"), Fixture.Commits, 2);
	}
	for (const FDefinition& Definition : Definitions)
	{
		TestTrue(Definition.AbilityId.ToString() + TEXT(": still on its own cooldown at the end"), AbilitySystem.HasMatchingGameplayTag(Definition.CooldownTag));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAbilitiesResourceBoundsTest,
	"Aetheln.GameCombat.Abilities.ResourceBounds",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAbilitiesResourceBoundsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarAbilityTests;

	// Content check: no configured cost exceeds the configured MaxEndurance.
	const float ConfiguredMaxEndurance = GetDefault<AAethelnPlayerState>()->ProvisionalInitialAttributes.MaxEndurance;
	for (const FDefinition& Definition : GetDefinitions())
	{
		TestTrue(
			Definition.AbilityId.ToString() + TEXT(": the configured cost is within the configured MaxEndurance"),
			Definition.Class->GetDefaultObject<UAethelnGameplayAbility>()->ProvisionalEnduranceCost <= ConfiguredMaxEndurance);
	}

	// The fixture outlives the world, so its delegate bindings never dangle during teardown.
	FOathscarFixture Fixture;
	FScopedCombatTestWorld TestWorld;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnGameplayAbility& GateStep = *Fixture.Instances[0];
	const float Endurance = Fixture.Endurance();
	TestTrue(TEXT("The test starts with Endurance"), Endurance > 0.0f);

	auto ExpectInsufficient = [&](const FString& Case, float Cost)
	{
		GateStep.ProvisionalEnduranceCost = Cost;
		const float Before = Fixture.Endurance();
		const int32 CommitsBefore = Fixture.Commits;
		ExpectResult(*this, Case, Fixture.Submit(0), EResult::InsufficientResource);
		TestEqual(Case + TEXT(": no partial spend"), Fixture.Endurance(), Before);
		TestEqual(Case + TEXT(": nothing committed"), Fixture.Commits, CommitsBefore);
		TestFalse(Case + TEXT(": not active"), Fixture.IsActive(0));
	};
	ExpectInsufficient(TEXT("Endurance below the cost"), Endurance + 1.0f);
	ExpectInsufficient(TEXT("A NaN cost fails closed"), std::numeric_limits<float>::quiet_NaN());
	ExpectInsufficient(TEXT("A negative cost fails closed"), -1.0f);
	TestEqual(TEXT("No cost effect was applied"), Fixture.CostEffects, 0);

	GateStep.ProvisionalEnduranceCost = Endurance;
	ExpectResult(*this, TEXT("A cost equal to Endurance"), Fixture.Submit(0), EResult::Accepted);
	TestEqual(TEXT("A cost equal to Endurance leaves 0"), Fixture.Endurance(), 0.0f);
	TestEqual(TEXT("It applied one cost effect"), Fixture.CostEffects, 1);

	ExpectInsufficient(TEXT("Any cost at 0 Endurance"), 1.0f);

	GateStep.ProvisionalEnduranceCost = 0.0f;
	ExpectResult(*this, TEXT("No cost at 0 Endurance"), Fixture.Submit(0), EResult::Accepted);
	TestEqual(TEXT("No cost applies no cost effect"), Fixture.CostEffects, 1);
	TestEqual(TEXT("No cost leaves Endurance at 0"), Fixture.Endurance(), 0.0f);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAbilitiesTagAndStateGatesTest,
	"Aetheln.GameCombat.Abilities.TagAndStateGates",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAbilitiesTagAndStateGatesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarAbilityTests;

	// The fixture outlives the world, so its delegate bindings never dangle during teardown.
	FOathscarFixture Fixture;
	FScopedCombatTestWorld TestWorld;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnAbilitySystemComponent& AbilitySystem = *Fixture.Player.AbilitySystem;

	const TArray<FDefinition> Definitions = GetDefinitions();
	for (int32 Index = 0; Index < Definitions.Num(); ++Index)
	{
		const FString Name = Definitions[Index].AbilityId.ToString();
		const FGameplayTagContainer AbilityIdTags(Definitions[Index].AbilityId);
		// A test-pinned cost, so a blocked request that spent anything would show.
		Fixture.Instances[Index]->ProvisionalEnduranceCost = 1.0f;

		auto ExpectBlocked = [&](const FString& Case)
		{
			const float Before = Fixture.Endurance();
			const int32 CommitsBefore = Fixture.Commits;
			ExpectResult(*this, Case, Fixture.Submit(Index), EResult::ActivationBlocked);
			TestEqual(Case + TEXT(": nothing spent"), Fixture.Endurance(), Before);
			TestEqual(Case + TEXT(": nothing committed"), Fixture.Commits, CommitsBefore);
			TestFalse(Case + TEXT(": not active"), Fixture.IsActive(Index));
		};

		AbilitySystem.AddLooseGameplayTag(AethelnGameplayTags::State_Dead);
		ExpectBlocked(Name + TEXT(" while State.Dead"));
		AbilitySystem.RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
		ExpectResult(*this, Name + TEXT(" after State.Dead is removed"), Fixture.Submit(Index), EResult::Accepted);

		// Which abilities block which is TBD (#60, #18), so the test blocks the ability the way an
		// active blocking ability would, through the ASC's blocked-ability tags.
		AbilitySystem.BlockAbilitiesWithTags(AbilityIdTags);
		ExpectBlocked(Name + TEXT(" while blocked by a test block"));
		AbilitySystem.UnBlockAbilitiesWithTags(AbilityIdTags);
		ExpectResult(*this, Name + TEXT(" after the block is removed"), Fixture.Submit(Index), EResult::Accepted);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAbilitiesDefinitionsAndVersionsTest,
	"Aetheln.GameCombat.Abilities.DefinitionsAndVersions",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAbilitiesDefinitionsAndVersionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnOathscarAbilityTests;

	const TArray<FDefinition> Definitions = GetDefinitions();
	const TArray<TSubclassOf<UGameplayAbility>>& Configured = GetDefault<AAethelnPlayerState>()->GrantedAbilities;
	TestEqual(TEXT("DefaultGame.ini grants exactly the three skeletons"), Configured.Num(), Definitions.Num());

	TSet<FGameplayTag> AbilityIds;
	TSet<FGameplayTag> CooldownTags;
	for (int32 Index = 0; Index < Definitions.Num(); ++Index)
	{
		const FDefinition& Definition = Definitions[Index];
		const FString Name = Definition.AbilityId.ToString();
		const UAethelnGameplayAbility* Ability = Definition.Class->GetDefaultObject<UAethelnGameplayAbility>();
		TestTrue(Name + TEXT(": granted by config, in order"), Configured.IsValidIndex(Index) && Configured[Index].Get() == Definition.Class.Get());

		TestEqual(Name + TEXT(": identity"), Ability->GetAbilityId(), Definition.AbilityId);
		TestTrue(Name + TEXT(": a valid Ability. tag"), UAethelnGameplayAbility::IsAbilityIdentityTag(Ability->GetAbilityId()));
		TestFalse(Name + TEXT(": a unique identity"), AbilityIds.Contains(Definition.AbilityId));
		AbilityIds.Add(Definition.AbilityId);
#if WITH_EDITORONLY_DATA
		const TSharedPtr<FGameplayTagNode> Node = UGameplayTagsManager::Get().FindTagNode(Definition.AbilityId);
		TestEqual(Name + TEXT(": the tag maps to its semantic ID"), Node.IsValid() ? Node->GetDevComment() : FString(), FString(Definition.SemanticId));
#endif

		int32 IniContentVersion = 0;
		TestTrue(Name + TEXT(": DefaultGame.ini sets ContentVersion"), GConfig->GetInt(*Definition.Class->GetPathName(), TEXT("ContentVersion"), IniContentVersion, GGameIni));
		TestEqual(Name + TEXT(": the class default loaded ContentVersion"), static_cast<int64>(Ability->ContentVersion), static_cast<int64>(IniContentVersion));
		TestTrue(Name + TEXT(": ContentVersion >= 1"), Ability->ContentVersion >= 1);

		TestTrue(Name + TEXT(": InstancedPerActor"), Ability->GetInstancingPolicy() == EGameplayAbilityInstancingPolicy::InstancedPerActor);
		TestTrue(Name + TEXT(": ServerOnly execution, nothing predicted"), Ability->GetNetExecutionPolicy() == EGameplayAbilityNetExecutionPolicy::ServerOnly);
		TestTrue(Name + TEXT(": ServerOnly security"), Ability->GetNetSecurityPolicy() == EGameplayAbilityNetSecurityPolicy::ServerOnly);
		const FGameplayTagContainer* AbilityCooldownTags = Ability->GetCooldownTags();
		TestTrue(Name + TEXT(": exactly its cooldown tag"), AbilityCooldownTags != nullptr && AbilityCooldownTags->Num() == 1 && AbilityCooldownTags->HasTagExact(Definition.CooldownTag));
		TestFalse(Name + TEXT(": a unique cooldown tag"), CooldownTags.Contains(Definition.CooldownTag));
		CooldownTags.Add(Definition.CooldownTag);
		TestNull(Name + TEXT(": no engine cost effect class"), Ability->GetCostGameplayEffect());
		TestNull(Name + TEXT(": no engine cooldown effect class"), Ability->GetCooldownGameplayEffect());
		TestFalse(Name + TEXT(": bAcceptsRelease is false"), Ability->bAcceptsRelease);
		TestTrue(Name + TEXT(": the definition passes grant validation"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition.Class, 1)));
	}

	// End to end through the configured grant list.
	// The fixture outlives the world, so its delegate bindings never dangle during teardown.
	FOathscarFixture Fixture;
	FScopedCombatTestWorld TestWorld;
	if (!Fixture.Init(*this, TestWorld, Configured))
	{
		return false;
	}
	TestEqual(TEXT("The configured grant list grants three abilities"), Fixture.Player.AbilitySystem->GetActivatableAbilities().Num(), Definitions.Num());
	for (int32 Index = 0; Index < Definitions.Num(); ++Index)
	{
		const FString Name = Definitions[Index].AbilityId.ToString();
		const uint32 ContentVersion = Definitions[Index].Class->GetDefaultObject<UAethelnGameplayAbility>()->ContentVersion;
		ExpectResult(*this, Name + TEXT(": a newer content version"), Fixture.Submit(Index, ContentVersion + 1), EResult::IncompatibleVersion);
		ExpectResult(*this, Name + TEXT(": an older content version"), Fixture.Submit(Index, ContentVersion - 1), EResult::IncompatibleVersion);
		TestEqual(Name + TEXT(": a version mismatch commits nothing"), Fixture.Commits, 0);
	}
	for (int32 Index = 0; Index < Definitions.Num(); ++Index)
	{
		ExpectResult(*this, Definitions[Index].AbilityId.ToString() + TEXT(": the matching content version"), Fixture.Submit(Index), EResult::Accepted);
	}
	return true;
}

#endif
