#if WITH_DEV_AUTOMATION_TESTS

#include "Abilities/GameplayAbility.h"
#include "AbilitySystemGlobals.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestAbilities.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/GameMode.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"

namespace AethelnAbilityLifecycleTests
{
	using AethelnCombatTests::AttachFreshPlayerState;
	using AethelnCombatTests::FScopedCombatTestWorld;
	using AethelnCombatTests::FTestPlayer;
	using AethelnCombatTests::MakeTestInitValues;
	using AethelnCombatTests::SpawnTestPlayer;

	UClass* GetLongRunningTestAbilityClass()
	{
		return UAethelnLongRunningTestAbility::StaticClass();
	}

	const FGameplayAbilitySpec* FindTestAbilitySpec(const UAbilitySystemComponent& AbilitySystem)
	{
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			if (Spec.Ability != nullptr && Spec.Ability->GetClass() == GetLongRunningTestAbilityClass())
			{
				return &Spec;
			}
		}
		return nullptr;
	}

	/** Activates the granted test ability through the seam, once per PlayerState, and returns its handle, or an invalid handle. */
	FGameplayAbilitySpecHandle ActivateTestAbility(FAutomationTestBase& Test, UAethelnAbilitySystemComponent& AbilitySystem)
	{
		const FGameplayAbilitySpec* Spec = FindTestAbilitySpec(AbilitySystem);
		if (!Test.TestNotNull(TEXT("Test ability is granted"), Spec))
		{
			return FGameplayAbilitySpecHandle();
		}
		const FGameplayAbilitySpecHandle Handle = Spec->Handle;
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = AethelnCombatTestTags::Ability_Test_LongRunning;
		Request.ContentVersion = GetDefault<UAethelnLongRunningTestAbility>()->ContentVersion;
		Request.Sequence = 1;
		Test.TestTrue(TEXT("Test ability activates on the server through the seam"), AbilitySystem.ProcessServerRequest(Request) == EAethelnActivationResult::Accepted);
		const FGameplayAbilitySpec* ActiveSpec = AbilitySystem.FindAbilitySpecFromHandle(Handle);
		Test.TestTrue(TEXT("Test ability stays active until cancelled"), ActiveSpec != nullptr && ActiveSpec->IsActive());
		return Handle;
	}

	bool IsAbilityActive(const UAbilitySystemComponent& AbilitySystem, const FGameplayAbilitySpecHandle Handle)
	{
		const FGameplayAbilitySpec* Spec = AbilitySystem.FindAbilitySpecFromHandle(Handle);
		return Spec != nullptr && Spec->IsActive();
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPlayerStateOwnsAbilitySystemTest,
	"Aetheln.GameCombat.Lifecycle.PlayerStateOwnsAbilitySystem",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPlayerStateOwnsAbilitySystemTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	const AAethelnCombatGameMode* GameModeDefaults = GetDefault<AAethelnCombatGameMode>();
	TestTrue(TEXT("Combat game mode spawns AAethelnPlayerState"), GameModeDefaults->PlayerStateClass.Get() == AAethelnPlayerState::StaticClass());
	TestFalse(TEXT("Combat game mode never derives from AGameMode"), AAethelnCombatGameMode::StaticClass()->IsChildOf(AGameMode::StaticClass()));

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Player.AbilitySystem;
	TestTrue(TEXT("Stock lookup finds the ASC through the PlayerState's interface"), UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(Player.PlayerState) == AbilitySystem);
	TestTrue(TEXT("ASC is a component of the PlayerState"), AbilitySystem->GetOwner() == Player.PlayerState);
	TestTrue(TEXT("Player ASC uses Mixed replication"), AbilitySystem->ReplicationMode == EGameplayEffectReplicationMode::Mixed);
	TestTrue(TEXT("Player ASC replicates"), AbilitySystem->GetIsReplicated());
	TestTrue(TEXT("Combat attribute set is registered in SpawnedAttributes"), AbilitySystem->GetSet<UAethelnCombatAttributeSet>() == Player.PlayerState->GetCombatAttributeSet());
	TestNotNull(TEXT("Combat attribute set exists"), Player.PlayerState->GetCombatAttributeSet());
	TestNull(TEXT("GameCore pawn has no ASC component"), Pawn->FindComponentByClass<UAbilitySystemComponent>());
	TestNull(TEXT("Stock lookup finds no ASC on the GameCore pawn"), UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(Pawn, true));
	TestTrue(TEXT("Owner is the PlayerState"), AbilitySystem->GetOwnerActor() == Player.PlayerState);
	TestNull(TEXT("Avatar is null before the first possession"), AbilitySystem->GetAvatarActor());
	TestEqual(TEXT("PlayerState uses the provisional update frequency"), Player.PlayerState->GetNetUpdateFrequency(), Player.PlayerState->ProvisionalNetUpdateFrequency);
	TestEqual(TEXT("No abilities are granted before possession"), AbilitySystem->GetActivatableAbilities().Num(), 0);

	// The ini sections load: the header default is 0, so only config can make the class default positive.
	float IniFrequency = 0.0f;
	TestTrue(TEXT("DefaultGame.ini sets ProvisionalNetUpdateFrequency"),
		GConfig->GetFloat(TEXT("/Script/GameCombat.AethelnPlayerState"), TEXT("ProvisionalNetUpdateFrequency"), IniFrequency, GGameIni));
	TestTrue(TEXT("The configured update frequency is positive"), IniFrequency > 0.0f);
	TestEqual(TEXT("The PlayerState class default loaded the ini value"), GetDefault<AAethelnPlayerState>()->ProvisionalNetUpdateFrequency, IniFrequency);
	for (UClass* ConfiguredClass : { AAethelnPlayerState::StaticClass(), AAethelnCombatAICharacter::StaticClass() })
	{
		const FString Section = FString::Printf(TEXT("/Script/GameCombat.%s"), *ConfiguredClass->GetName());
		FString IniAttributes;
		FAethelnCombatAttributeInitValues ParsedAttributes;
		const FProperty* Property = FindFProperty<FProperty>(ConfiguredClass, TEXT("ProvisionalInitialAttributes"));
		TestTrue(*FString::Printf(TEXT("%s sets ProvisionalInitialAttributes"), *Section),
			GConfig->GetString(*Section, TEXT("ProvisionalInitialAttributes"), IniAttributes, GGameIni));
		TestTrue(*FString::Printf(TEXT("%s ProvisionalInitialAttributes parses"), *Section),
			Property != nullptr && Property->ImportText_Direct(*IniAttributes, &ParsedAttributes, nullptr, PPF_None) != nullptr);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPossessionSetsAvatarTest,
	"Aetheln.GameCombat.Lifecycle.PossessionSetsAvatar",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPossessionSetsAvatarTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Player.AbilitySystem;
	int32 MaxHealthChanges = 0;
	AbilitySystem->GetGameplayAttributeValueChangeDelegate(UAethelnCombatAttributeSet::GetMaxHealthAttribute()).AddLambda(
		[&MaxHealthChanges](const FOnAttributeChangeData&) { ++MaxHealthChanges; });

	Player.Controller->Possess(Pawn);
	TestTrue(TEXT("PlayerState now has the pawn"), Player.PlayerState->GetPawn() == Pawn);
	TestTrue(TEXT("Possessed pawn is the avatar"), AbilitySystem->GetAvatarActor() == Pawn);
	TestTrue(TEXT("Owner stays the PlayerState"), AbilitySystem->GetOwnerActor() == Player.PlayerState);
	TestEqual(TEXT("Configured abilities are granted once"), AbilitySystem->GetActivatableAbilities().Num(), 1);
	TestNotNull(TEXT("The configured ability is the granted one"), FindTestAbilitySpec(*AbilitySystem));
	TestEqual(TEXT("Attributes are initialized once"), MaxHealthChanges, 1);
	TestEqual(TEXT("MaxHealth has its configured value"), AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetMaxHealthAttribute()), MakeTestInitValues().MaxHealth);

	Player.Controller->UnPossess();
	Player.Controller->Possess(Pawn);
	TestTrue(TEXT("Re-possessed pawn is the avatar again"), AbilitySystem->GetAvatarActor() == Pawn);
	TestEqual(TEXT("Re-possession grants nothing more"), AbilitySystem->GetActivatableAbilities().Num(), 1);
	TestEqual(TEXT("Re-possession does not initialize again"), MaxHealthChanges, 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnUnpossessCancelsAndClearsAvatarTest,
	"Aetheln.GameCombat.Lifecycle.UnpossessCancelsAndClearsAvatar",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnUnpossessCancelsAndClearsAvatarTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Player.AbilitySystem;
	Player.Controller->Possess(Pawn);
	const FGameplayAbilitySpecHandle AbilityHandle = ActivateTestAbility(*this, *AbilitySystem);
	const FActiveGameplayEffectHandle EffectHandle = AbilitySystem->ApplyGameplayEffectToSelf(
		AethelnCombatTests::MakeTestEffect(EGameplayEffectDurationType::Infinite), 1.0f, AbilitySystem->MakeEffectContext());
	TestTrue(TEXT("Test duration effect is active"), AbilitySystem->GetActiveGameplayEffect(EffectHandle) != nullptr);

	Player.Controller->UnPossess();
	TestNull(TEXT("PlayerState has no pawn after unpossession"), Player.PlayerState->GetPawn());
	TestFalse(TEXT("Unpossession cancels the running ability"), IsAbilityActive(*AbilitySystem, AbilityHandle));
	TestNull(TEXT("Unpossession clears the avatar"), AbilitySystem->GetAvatarActor());
	TestTrue(TEXT("Owner stays the PlayerState"), AbilitySystem->GetOwnerActor() == Player.PlayerState);
	TestTrue(TEXT("Test duration effect persists across the avatar change"), AbilitySystem->GetActiveGameplayEffect(EffectHandle) != nullptr);
	TestNotNull(TEXT("Granted ability persists"), FindTestAbilitySpec(*AbilitySystem));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAvatarReassignmentTest,
	"Aetheln.GameCombat.Lifecycle.AvatarReassignment",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAvatarReassignmentTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* PawnA = TestWorld.Spawn<AAethelnPlayerCharacter>();
	AAethelnPlayerCharacter* PawnB = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("Pawn A exists"), PawnA) || !TestNotNull(TEXT("Pawn B exists"), PawnB))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Player.AbilitySystem;
	int32 MaxHealthChanges = 0;
	AbilitySystem->GetGameplayAttributeValueChangeDelegate(UAethelnCombatAttributeSet::GetMaxHealthAttribute()).AddLambda(
		[&MaxHealthChanges](const FOnAttributeChangeData&) { ++MaxHealthChanges; });

	Player.Controller->Possess(PawnA);
	const FGameplayAbilitySpecHandle AbilityHandle = ActivateTestAbility(*this, *AbilitySystem);
	AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
	const float HealthBeforeSwitch = AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute());
	TestEqual(TEXT("Test damage lowered Health"), HealthBeforeSwitch, MakeTestInitValues().Health - 10.0f);

	// A real Possess: the engine unpossesses A (A to null), then possesses B (null to B).
	Player.Controller->Possess(PawnB);
	TestTrue(TEXT("Pawn B is the avatar"), AbilitySystem->GetAvatarActor() == PawnB);
	TestTrue(TEXT("Owner stays the PlayerState"), AbilitySystem->GetOwnerActor() == Player.PlayerState);
	TestNull(TEXT("Pawn A no longer resolves to the PlayerState ASC"), UAethelnAbilitySystemComponent::FindForPawn(PawnA));
	TestFalse(TEXT("Leaving pawn A cancelled the running ability"), IsAbilityActive(*AbilitySystem, AbilityHandle));
	TestEqual(TEXT("No re-grant: spec count is stable"), AbilitySystem->GetActivatableAbilities().Num(), 1);
	TestEqual(TEXT("No refill: Health is unchanged"), AbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), HealthBeforeSwitch);
	TestEqual(TEXT("No re-initialization"), MaxHealthChanges, 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAvatarDestroyedWhilePossessedTest,
	"Aetheln.GameCombat.Lifecycle.AvatarDestroyedWhilePossessed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAvatarDestroyedWhilePossessedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Player.AbilitySystem;
	Player.Controller->Possess(Pawn);
	const FGameplayAbilitySpecHandle AbilityHandle = ActivateTestAbility(*this, *AbilitySystem);

	TestTrue(TEXT("Possessed pawn is destroyed"), Pawn->Destroy());
	TestNull(TEXT("Controller has no pawn"), Player.Controller->GetPawn());
	TestNull(TEXT("PlayerState has no pawn"), Player.PlayerState->GetPawn());
	TestNull(TEXT("Avatar is null after the destroyed pawn's null case"), AbilitySystem->GetAvatarActor());
	// A weak pointer to a destroyed pawn also reads null; only an explicit clear leaves it explicitly null.
	TestTrue(TEXT("The null case cleared the avatar explicitly"), AbilitySystem->AbilityActorInfo->AvatarActor.IsExplicitlyNull());
	TestFalse(TEXT("The null case cancelled the running ability"), IsAbilityActive(*AbilitySystem, AbilityHandle));
	TestTrue(TEXT("Owner stays the PlayerState"), AbilitySystem->GetOwnerActor() == Player.PlayerState);
	TestTrue(TEXT("PlayerState ASC is intact"), Player.PlayerState->GetAbilitySystemComponent() == AbilitySystem);
	TestNotNull(TEXT("Attribute set is intact"), AbilitySystem->GetSet<UAethelnCombatAttributeSet>());
	TestNotNull(TEXT("Granted ability is intact"), FindTestAbilitySpec(*AbilitySystem));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAIPawnOwnsAbilitySystemTest,
	"Aetheln.GameCombat.Lifecycle.AIPawnOwnsAbilitySystem",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAIPawnOwnsAbilitySystemTest::RunTest(const FString& Parameters)
{
	AethelnCombatTests::FScopedCombatTestWorld TestWorld;
	if (!TestNotNull(TEXT("Test world exists"), TestWorld.World))
	{
		return false;
	}
	AAethelnCombatAICharacter* Character = TestWorld.Spawn<AAethelnCombatAICharacter>();
	if (!TestNotNull(TEXT("AI character exists"), Character))
	{
		return false;
	}

	UAethelnAbilitySystemComponent* AbilitySystem = Character->GetAethelnAbilitySystemComponent();
	if (!TestNotNull(TEXT("AI character owns the project ASC"), AbilitySystem))
	{
		return false;
	}
	TestTrue(TEXT("ASC is a component of the AI pawn"), AbilitySystem->GetOwner() == Character);
	TestTrue(TEXT("Stock lookup finds the AI pawn's ASC"), UAbilitySystemGlobals::GetAbilitySystemComponentFromActor(Character) == AbilitySystem);
	TestTrue(TEXT("AI ASC uses Minimal replication"), AbilitySystem->ReplicationMode == EGameplayEffectReplicationMode::Minimal);
	TestTrue(TEXT("Combat attribute set is registered on the AI ASC"), AbilitySystem->GetSet<UAethelnCombatAttributeSet>() == Character->GetCombatAttributeSet());
	TestTrue(TEXT("Owner is the AI pawn"), AbilitySystem->GetOwnerActor() == Character);
	TestTrue(TEXT("Avatar is the AI pawn"), AbilitySystem->GetAvatarActor() == Character);
	TestNull(TEXT("AI pawn has no PlayerState"), Character->GetPlayerState());

	// Clear a field only actor-info initialization fills, so the refresh on possession is observable.
	AbilitySystem->AbilityActorInfo->MovementComponent = nullptr;
	Character->SpawnDefaultController();
	AController* Controller = Character->GetController();
	TestNotNull(TEXT("AI controller possesses the pawn"), Controller);
	TestNull(TEXT("Possessor is not a player controller"), Cast<APlayerController>(Controller));
	TestNull(TEXT("AI possession involves no PlayerState"), Character->GetPlayerState());
	TestTrue(TEXT("Possession refreshes the actor info"), AbilitySystem->AbilityActorInfo->MovementComponent.Get() == Character->GetCharacterMovement());
	TestTrue(TEXT("Owner stays the AI pawn"), AbilitySystem->GetOwnerActor() == Character);
	TestTrue(TEXT("Avatar stays the AI pawn"), AbilitySystem->GetAvatarActor() == Character);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnPawnToAbilitySystemLookupTest,
	"Aetheln.GameCombat.Lifecycle.PawnToAbilitySystemLookup",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnPawnToAbilitySystemLookupTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* PlayerPawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	AAethelnPlayerCharacter* PlainPawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	AAethelnCombatAICharacter* AICharacter = TestWorld.Spawn<AAethelnCombatAICharacter>();
	if (!TestNotNull(TEXT("Player pawn exists"), PlayerPawn)
		|| !TestNotNull(TEXT("Plain pawn exists"), PlainPawn)
		|| !TestNotNull(TEXT("AI character exists"), AICharacter))
	{
		return false;
	}

	Player.Controller->Possess(PlayerPawn);
	TestTrue(TEXT("Player pawn resolves to the PlayerState ASC"), UAethelnAbilitySystemComponent::FindForPawn(PlayerPawn) == Player.AbilitySystem);
	TestTrue(TEXT("AI pawn resolves to its own ASC"), UAethelnAbilitySystemComponent::FindForPawn(AICharacter) == AICharacter->GetAethelnAbilitySystemComponent());
	TestNull(TEXT("A pawn with neither resolves to null"), UAethelnAbilitySystemComponent::FindForPawn(PlainPawn));
	TestNull(TEXT("A null pawn resolves to null"), UAethelnAbilitySystemComponent::FindForPawn(nullptr));

	Player.Controller->UnPossess();
	TestNull(TEXT("An unpossessed former player pawn resolves to null"), UAethelnAbilitySystemComponent::FindForPawn(PlayerPawn));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnReconnectInterimGapTest,
	"Aetheln.GameCombat.Lifecycle.ReconnectInterimGap",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnReconnectInterimGapTest::RunTest(const FString& Parameters)
{
	using namespace AethelnAbilityLifecycleTests;

	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}

	Player.Controller->Possess(Pawn);
	AethelnCombatTests::ApplyInstantModifier(*Player.AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute(), EGameplayModOp::AddBase, -10.0f);
	Player.AbilitySystem->ApplyGameplayEffectToSelf(
		AethelnCombatTests::MakeTestEffect(EGameplayEffectDurationType::Infinite), 1.0f, Player.AbilitySystem->MakeEffectContext());
	TestEqual(TEXT("Old PlayerState carries one active effect (a stand-in for a cooldown)"), Player.AbilitySystem->GetNumActiveGameplayEffects(), 1);

	// AGameModeBase never reuses an inactive PlayerState, so a reconnect gets a fresh one.
	Player.Controller->UnPossess();
	AAethelnPlayerState* ReconnectedPlayerState = AttachFreshPlayerState(TestWorld, *Player.Controller);
	if (!TestNotNull(TEXT("Fresh PlayerState exists"), ReconnectedPlayerState))
	{
		return false;
	}
	Player.PlayerState->Destroy();
	Player.Controller->Possess(Pawn);

	// Known interim gap, owned by #21: reconnect is a free refill. #21 flips these assertions.
	UAethelnAbilitySystemComponent* ReconnectedAbilitySystem = ReconnectedPlayerState->GetAethelnAbilitySystemComponent();
	TestTrue(TEXT("Pawn resolves to the fresh PlayerState ASC"), UAethelnAbilitySystemComponent::FindForPawn(Pawn) == ReconnectedAbilitySystem);
	TestEqual(TEXT("Interim gap: Health is refilled to its configured value"), ReconnectedAbilitySystem->GetNumericAttribute(UAethelnCombatAttributeSet::GetHealthAttribute()), MakeTestInitValues().Health);
	TestEqual(TEXT("Interim gap: no effect carries over"), ReconnectedAbilitySystem->GetNumActiveGameplayEffects(), 0);
	TestEqual(TEXT("Interim gap: abilities are granted again"), ReconnectedAbilitySystem->GetActivatableAbilities().Num(), 1);
	return true;
}

#endif
