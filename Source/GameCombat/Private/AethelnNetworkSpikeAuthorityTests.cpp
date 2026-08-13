#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeAuthorityTypes.h"
#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeMeleeAbility.h"
#include "AethelnNetworkSpikeGameMode.h"
#include "AbilitySystemComponent.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "Misc/AutomationTest.h"
#include "Misc/CommandLine.h"
#include "Misc/OutputDevice.h"
#include "Misc/OutputDeviceRedirector.h"
#include "UObject/UnrealType.h"

namespace AethelnNetworkSpikeAuthorityTests
{
	class FScopedAuthorityLogCapture final : public FOutputDevice
	{
	public:
		FScopedAuthorityLogCapture()
			: OriginalCommandLine(FCommandLine::Get())
		{
			if (GLog != nullptr)
			{
				GLog->AddOutputDevice(this);
				bRegistered = true;
			}
		}

		virtual ~FScopedAuthorityLogCapture() override
		{
			FCommandLine::Set(*OriginalCommandLine);
			if (bRegistered && GLog != nullptr)
			{
				GLog->FlushThreadedLogs();
				GLog->RemoveOutputDevice(this);
			}
		}

		virtual void Serialize(const TCHAR* Message, ELogVerbosity::Type Verbosity, const FName& Category) override
		{
			AddObservedStages(Message);
		}

		void SetScenarioEnabled(bool bEnabled)
		{
			FCommandLine::Set(bEnabled ? TEXT("-AethelnAuthorityScenario") : TEXT(""));
		}

		void Reset()
		{
			FlushThreadedLogs();
			ObservedStages.Reset();
		}

		int32 CountStage(const FString& Stage) const
		{
			FlushThreadedLogs();
			int32 Result = 0;
			for (const FString& ObservedStage : ObservedStages)
			{
				if (ObservedStage == Stage)
				{
					++Result;
				}
			}
			return Result;
		}

		int32 Num() const
		{
			FlushThreadedLogs();
			return ObservedStages.Num();
		}

	private:
		void FlushThreadedLogs() const
		{
			if (GLog != nullptr)
			{
				GLog->FlushThreadedLogs();
			}
		}

		void AddObservedStages(const FString& Line)
		{
			const FString Marker(TEXT("stage="));
			int32 MarkerStart = Line.Find(Marker, ESearchCase::CaseSensitive);
			while (MarkerStart != INDEX_NONE)
			{
				const int32 StageStart = MarkerStart + Marker.Len();
				int32 StageEnd = Line.Find(TEXT(" "), ESearchCase::CaseSensitive, ESearchDir::FromStart, StageStart);
				if (StageEnd == INDEX_NONE)
				{
					StageEnd = Line.Len();
				}
				if (StageEnd > StageStart)
				{
					ObservedStages.Add(Line.Mid(StageStart, StageEnd - StageStart));
				}
				MarkerStart = Line.Find(Marker, ESearchCase::CaseSensitive, ESearchDir::FromStart, StageEnd);
			}
		}

		FString OriginalCommandLine;
		TArray<FString> ObservedStages;
		bool bRegistered = false;
	};
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnNetworkSpikeAuthorityTest,
	"Aetheln.GameCombat.NetworkSpike.Authority",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkSpikeAuthorityTest::RunTest(const FString& Parameters)
{
	const UScriptStruct* IntentStruct = FAethelnSpikeAttackIntent::StaticStruct();
	TestNotNull(TEXT("Intent schema exists"), IntentStruct);

	int32 ReflectedFieldCount = 0;
	for (TFieldIterator<FProperty> PropertyIt(IntentStruct, EFieldIteratorFlags::ExcludeSuper); PropertyIt; ++PropertyIt)
	{
		++ReflectedFieldCount;
	}
	TestEqual(TEXT("Intent has exactly five bounded input fields"), ReflectedFieldCount, 5);
	TestNull(TEXT("Target is structurally absent"), IntentStruct->FindPropertyByName(TEXT("Target")));
	TestNull(TEXT("Hit is structurally absent"), IntentStruct->FindPropertyByName(TEXT("Hit")));
	TestNull(TEXT("Damage is structurally absent"), IntentStruct->FindPropertyByName(TEXT("Damage")));
	TestEqual(TEXT("Activation refusal reason is stable"), FString(LexToString(EAethelnSpikeAttackRejection::ActivationBlocked)), FString(TEXT("activation-blocked")));
	TestEqual(TEXT("Impossible aim refusal reason is stable"), FString(LexToString(EAethelnSpikeAttackRejection::ImpossibleAimTransition)), FString(TEXT("impossible-aim-transition")));
	for (const TCHAR* Category : { TEXT("movement"), TEXT("aim"), TEXT("activation"), TEXT("hit"), TEXT("cooldown"), TEXT("dodge"), TEXT("block"), TEXT("damage"), TEXT("disconnected-command") })
	{
		TestEqual(
			*FString::Printf(TEXT("%s evidence category has stable lowercase identity"), Category),
			UAethelnSpikeAuthorityComponent::GetScenarioCategoryId(FName(Category)),
			FString(Category));
	}

	TestTrue(TEXT("Initial client one label is accepted only for spike correlation"), AAethelnNetworkSpikeGameMode::IsAllowedScenarioClientId(TEXT("client-1")));
	TestTrue(TEXT("Initial client two label is accepted only for spike correlation"), AAethelnNetworkSpikeGameMode::IsAllowedScenarioClientId(TEXT("client-2")));
	TestTrue(TEXT("Reconnect label is accepted only for spike correlation"), AAethelnNetworkSpikeGameMode::IsAllowedScenarioClientId(TEXT("client-1-reconnect")));
	TestFalse(TEXT("Arbitrary client labels are rejected"), AAethelnNetworkSpikeGameMode::IsAllowedScenarioClientId(TEXT("admin")));
	TestNotEqual(TEXT("Server connection identities are unique"), AAethelnNetworkSpikeGameMode::MakeScenarioConnectionId(TEXT("run-1"), 1), AAethelnNetworkSpikeGameMode::MakeScenarioConnectionId(TEXT("run-1"), 2));

	TestFalse(TEXT("Attack waits for client readiness"), AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(TEXT("client-1"), false, 2.0f, false));
	TestFalse(TEXT("Only client one submits the scenario attack"), AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(TEXT("client-2"), true, 2.0f, false));
	TestFalse(TEXT("Attack waits for the elapsed-time threshold"), AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(TEXT("client-1"), true, 1.99f, false));
	TestTrue(TEXT("Ready client one submits without an observed enemy input"), AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(TEXT("client-1"), true, 2.0f, false));
	TestFalse(TEXT("Scenario attack is submitted only once"), AAethelnSpikeCharacter::ShouldSubmitScenarioAttack(TEXT("client-1"), true, 3.0f, true));

	UWorld* World = UWorld::CreateWorld(EWorldType::Game, false);
	TestNotNull(TEXT("Behavioral authority world was created"), World);
	if (World == nullptr)
	{
		return false;
	}

	TestNotNull(TEXT("Engine exists for behavioral authority world"), GEngine);
	if (GEngine == nullptr)
	{
		World->DestroyWorld(false);
		return false;
	}

	FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
	WorldContext.SetCurrentWorld(World);
	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	FActorSpawnParameters SpawnParameters;
	SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AAethelnSpikeEnemy* Attacker = World->SpawnActor<AAethelnSpikeEnemy>(
		AAethelnSpikeEnemy::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
	AAethelnSpikeEnemy* Target = World->SpawnActor<AAethelnSpikeEnemy>(
		AAethelnSpikeEnemy::StaticClass(), FVector(175.0f, 0.0f, 0.0f), FRotator::ZeroRotator, SpawnParameters);
	TestNotNull(TEXT("Authoritative attacker pawn exists"), Attacker);
	TestNotNull(TEXT("Authoritative target pawn exists"), Target);
	if (Attacker == nullptr || Target == nullptr)
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}
	TestTrue(TEXT("Scenario enemy movement replicates after server positioning"), Target->IsReplicatingMovement());

	UAethelnSpikeAuthorityComponent* AuthorityComponent = NewObject<UAethelnSpikeAuthorityComponent>(Attacker, TEXT("TestAuthorityComponent"));
	AuthorityComponent->RegisterComponent();
	AuthorityComponent->SetLifecycleReady(true);
	FAethelnSpikeScenarioProbe Probe;
	Probe.Sequence = 1;
	Probe.Category = TEXT("movement");
	Probe.ClaimedMovement = FVector(100000.0f, 0.0f, 0.0f);
	TestEqual(TEXT("Impossible movement claim is validated against authoritative position"), AuthorityComponent->ValidateScenarioProbe(Probe), EAethelnSpikeAttackRejection::MalformedIntent);
	Probe.Category = TEXT("aim");
	Probe.ClaimedAim = -FVector::ForwardVector;
	TestEqual(TEXT("Impossible aim claim is validated against authoritative aim"), AuthorityComponent->ValidateScenarioProbe(Probe), EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	for (const FName ActivationCategory : { FName(TEXT("activation")), FName(TEXT("cooldown")), FName(TEXT("dodge")), FName(TEXT("block")) })
	{
		Probe.Category = ActivationCategory;
		TestEqual(*FString::Printf(TEXT("%s command is unavailable and fails closed"), *ActivationCategory.ToString()), AuthorityComponent->ValidateScenarioProbe(Probe), EAethelnSpikeAttackRejection::ActivationBlocked);
	}
	for (const FName OutcomeCategory : { FName(TEXT("hit")), FName(TEXT("damage")) })
	{
		Probe.Category = OutcomeCategory;
		Probe.ClaimedOutcome = OutcomeCategory;
		Probe.ClaimedMagnitude = 100000.0f;
		TestEqual(*FString::Printf(TEXT("%s outcome claim is structurally rejected"), *OutcomeCategory.ToString()), AuthorityComponent->ValidateScenarioProbe(Probe), EAethelnSpikeAttackRejection::MalformedIntent);
	}
	AuthorityComponent->SetLifecycleReady(false);
	Probe.Category = TEXT("disconnected-command");
	TestEqual(TEXT("Closed lifecycle rejects an actual post-disconnect command"), AuthorityComponent->ValidateScenarioProbe(Probe), EAethelnSpikeAttackRejection::ConnectionClosed);
	AuthorityComponent->SetLifecycleReady(true);
	UAbilitySystemComponent* AttackerAbilitySystem = Attacker->GetAbilitySystemComponent();
	UAbilitySystemComponent* TargetAbilitySystem = Target->GetAbilitySystemComponent();
	TestNotNull(TEXT("Attacker owns an ASC"), AttackerAbilitySystem);
	TestNotNull(TEXT("Target pawn owns an ASC"), TargetAbilitySystem);
	if (AttackerAbilitySystem == nullptr || TargetAbilitySystem == nullptr)
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}
	AttackerAbilitySystem->InitAbilityActorInfo(Attacker, Attacker);
	TargetAbilitySystem->InitAbilityActorInfo(Target, Target);

	AethelnNetworkSpikeAuthorityTests::FScopedAuthorityLogCapture LogCapture;
	FAethelnSpikeAttackIntent Intent;
	Intent.Sequence = 1;
	Intent.ClientTimestampSeconds = World->GetTimeSeconds();
	Intent.Aim = -FVector::ForwardVector;

	const float InitialHealth = Target->GetHealth();
	LogCapture.SetScenarioEnabled(false);
	AuthorityComponent->SubmitAttack(-FVector::ForwardVector);
	TestEqual(TEXT("Disabled authority scenario emits no authority stages"), LogCapture.Num(), 0);
	TestEqual(TEXT("Disabled authority scenario causes no damage"), Target->GetHealth(), InitialHealth);

	LogCapture.Reset();
	LogCapture.SetScenarioEnabled(true);
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Client aim conflicting with authoritative view is rejected"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	TestEqual(TEXT("Impossible aim transition causes no damage"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Impossible aim transition never opens the attack window"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Impossible aim transition creates no activation identity"), AuthorityComponent->GetActiveAttackId().IsValid());
	TestEqual(TEXT("Rejected command records validation"), LogCapture.CountStage(TEXT("validation")), 1);
	TestEqual(TEXT("Rejected command records terminal"), LogCapture.CountStage(TEXT("terminal")), 1);

	LogCapture.Reset();
	Intent.Aim = FVector::ForwardVector;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Unavailable GAS ability has a truthful refusal"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ActivationBlocked);
	TestEqual(TEXT("Activation refusal causes no damage"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Activation refusal closes the authored attack window"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Activation refusal retires the activation identity"), AuthorityComponent->GetActiveAttackId().IsValid());
	TestEqual(TEXT("Blocked command records validation"), LogCapture.CountStage(TEXT("validation")), 1);
	TestEqual(TEXT("Blocked command records activation request"), LogCapture.CountStage(TEXT("activation-request")), 1);
	TestEqual(TEXT("Blocked command records activation result"), LogCapture.CountStage(TEXT("activation-result")), 1);
	TestEqual(TEXT("Blocked command records terminal"), LogCapture.CountStage(TEXT("terminal")), 1);

	AttackerAbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnSpikeMeleeAbility::StaticClass(), 1));
	LogCapture.Reset();
	AuthorityComponent->SubmitAttack(FVector::ForwardVector);
	TestEqual(TEXT("The refused sequence remains retryable after the GAS block clears"), Target->GetHealth(), InitialHealth - 25.0f);
	TestEqual(TEXT("Successful retry clears the refusal"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::None);
	TestFalse(TEXT("Authored attack window closes after resolution"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Activation identity is retired with its window"), AuthorityComponent->GetActiveAttackId().IsValid());
	const TArray<FString> ExpectedStages = {
		TEXT("submission"),
		TEXT("rpc-receipt"),
		TEXT("validation"),
		TEXT("activation-request"),
		TEXT("activation-result"),
		TEXT("resolution"),
		TEXT("terminal")
	};
	TestEqual(TEXT("Successful authority request records exactly seven stages"), LogCapture.Num(), ExpectedStages.Num());
	for (const FString& ExpectedStage : ExpectedStages)
	{
		TestEqual(
			*FString::Printf(TEXT("Successful authority request records %s exactly once"), *ExpectedStage),
			LogCapture.CountStage(ExpectedStage),
			1);
	}

	const float HealthAfterFirstActivation = Target->GetHealth();
	LogCapture.Reset();
	Intent.Sequence = 2;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Accepted sequence becomes a duplicate"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::DuplicateSequence);
	TestEqual(TEXT("Duplicate command cannot deal additional damage"), Target->GetHealth(), HealthAfterFirstActivation);
	TestEqual(TEXT("Duplicate command records validation"), LogCapture.CountStage(TEXT("validation")), 1);
	TestEqual(TEXT("Duplicate command records terminal"), LogCapture.CountStage(TEXT("terminal")), 1);

	Intent.Sequence = 3;
	Intent.SchemaVersion = 2;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Invalid version causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	Intent.SchemaVersion = 1;

	Intent.Sequence = 4;
	Intent.Aim = FVector::ZeroVector;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Invalid aim causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	Intent.Aim = FVector::ForwardVector;

	AuthorityComponent->SetLifecycleReady(false);
	Intent.Sequence = 5;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Closed lifecycle causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	AuthorityComponent->SetLifecycleReady(true);

	const float HealthBeforeDestroyedTargetRequest = Target->GetHealth();
	Target->Destroy();
	Intent.Sequence = 6;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Destroyed target receives no further effect"), Target->GetHealth(), HealthBeforeDestroyedTargetRequest);

	World->DestroyWorld(false);
	GEngine->DestroyWorldContext(World);
	return true;
}

#endif
