#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeAuthorityTypes.h"
#include "AethelnSpikeCharacter.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeMeleeAbility.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnNetworkSpikeGameMode.h"
#include "AbilitySystemComponent.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
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
	AddExpectedMessagePlain(
		TEXT("LogAbilitySystem: No GameplayCueNotifyPaths were specified in DefaultGame.ini under [/Script/GameplayAbilities.AbilitySystemGlobals]. Falling back to using all of /Game/. This may be slow on large projects. Consider specifying which paths are to be searched."),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=impossible-aim-transition"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		4);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=activation-blocked"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=duplicate-sequence"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=incompatible-version"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=malformed-intent"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	AddExpectedMessagePlain(
		TEXT("LogTemp: AethelnSpikeAttackRejected Reason=connection-closed"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Exact,
		1);
	for (const TCHAR* ExpectedAuthorityWarning : {
		TEXT("LogTemp: AUTHORITY rejection category=movement reason=malformed-intent client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=aim reason=impossible-aim-transition client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=activation reason=activation-blocked client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=cooldown reason=activation-blocked client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=hit reason=malformed-intent client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=dodge reason=activation-blocked client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=block reason=activation-blocked client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=resource reason=malformed-intent client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=death reason=malformed-intent client=client-test scenario= profile= run="),
		TEXT("LogTemp: AUTHORITY rejection category=respawn reason=malformed-intent client=client-test scenario= profile= run=")
	})
	{
		AddExpectedMessagePlain(
			ExpectedAuthorityWarning,
			ELogVerbosity::Warning,
			EAutomationExpectedMessageFlags::Exact,
			1);
	}
	AddExpectedMessage(
		TEXT("dispatch_failure metric=\\\"sink-failure-count\\\" channel=\\\"public\\\" kind=\\\"sink-write\\\" work_class=\\\"critical\\\" delta=1 total=[12]"),
		ELogVerbosity::Warning,
		EAutomationExpectedMessageFlags::Contains,
		2);
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
	for (const TCHAR* Category : { TEXT("movement"), TEXT("aim"), TEXT("activation"), TEXT("hit"), TEXT("cooldown"), TEXT("dodge"), TEXT("block"), TEXT("resource"), TEXT("death"), TEXT("respawn"), TEXT("damage"), TEXT("disconnected-command") })
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
	TestEqual(
		TEXT("Scenario enemy follows authoritative client one at the authored attack reach"),
		AAethelnNetworkSpikeGameMode::MakeScenarioEnemyLocation(FVector(100.0f, 200.0f, 300.0f), FVector(10.0f, 0.0f, 0.0f)),
		FVector(275.0f, 200.0f, 300.0f));

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
	UGameInstance* GameInstance = NewObject<UGameInstance>(GEngine);
	TestNotNull(TEXT("Behavioral authority game instance was created"), GameInstance);
	if (GameInstance == nullptr)
	{
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}
	WorldContext.OwningGameInstance = GameInstance;
	World->SetGameInstance(GameInstance);
	WorldContext.SetCurrentWorld(World);
	GameInstance->Init();
	World->InitializeActorsForPlay(FURL());
	World->BeginPlay();

	UAethelnObservabilitySubsystem* ObservabilitySubsystem = GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>();
	TestNotNull(TEXT("Game instance owns the observability service"), ObservabilitySubsystem);
	TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe> ObservabilitySink =
		MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
	if (ObservabilitySubsystem == nullptr
		|| !ObservabilitySubsystem->SetRuntimeContext(
			EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-authority-test"),
			TEXT("instance-authority-test"),
			TEXT("connection-authority-test")))
	{
		GameInstance->Shutdown();
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}

	{
		AethelnNetworkSpikeAuthorityTests::FScopedAuthorityLogCapture ScenarioCommandLine;
		ScenarioCommandLine.SetScenarioEnabled(true);
		FActorSpawnParameters ScenarioCharacterSpawnParameters;
		ScenarioCharacterSpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
		AAethelnSpikeCharacter* ServerScenarioCharacter = World->SpawnActor<AAethelnSpikeCharacter>(
			AAethelnSpikeCharacter::StaticClass(),
			FVector(10000.0f, 0.0f, 0.0f),
			FRotator::ZeroRotator,
			ScenarioCharacterSpawnParameters);
		TestNotNull(TEXT("Server scenario character exists for process-correlation regression"), ServerScenarioCharacter);
		FAethelnObservabilityEventContext ServerLifecycleContext;
		ServerLifecycleContext.Sequence = 1;
		FAethelnCorrelationContext ServerLifecycleCorrelation;
		TestTrue(
			TEXT("Server lifecycle correlation remains composable after a server character begins play"),
			ObservabilitySubsystem->TryComposeCorrelation(
				EAethelnObservabilityCategory::ServerLifecycle,
				ServerLifecycleContext,
				ServerLifecycleCorrelation));
		TestEqual(
			TEXT("Server character initialization cannot relabel the process as a client"),
			ServerLifecycleCorrelation.InstanceId,
			FString(TEXT("instance-authority-test")));
		TestEqual(
			TEXT("Server character initialization cannot replace the server run identity"),
			ServerLifecycleCorrelation.RunId,
			FString(TEXT("run-authority-test")));
	}

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
		GameInstance->Shutdown();
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
		GameInstance->Shutdown();
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
	if (!ObservabilitySubsystem->SetTestSink(ObservabilitySink))
	{
		GameInstance->Shutdown();
		World->DestroyWorld(false);
		GEngine->DestroyWorldContext(World);
		return false;
	}

	LogCapture.Reset();
	LogCapture.SetScenarioEnabled(true);
	AuthorityComponent->ProcessServerIntent(Intent);
	TestTrue(TEXT("Impossible aim observability dispatch drains"), ObservabilitySubsystem->WaitForIdleForTests());
	TestEqual(TEXT("Client aim conflicting with authoritative view is rejected"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	TestEqual(TEXT("Impossible aim transition causes no damage"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Impossible aim transition never opens the attack window"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Impossible aim transition creates no activation identity"), AuthorityComponent->GetActiveAttackId().IsValid());
	TestEqual(TEXT("Rejected command records validation"), LogCapture.CountStage(TEXT("validation")), 1);
	TestEqual(TEXT("Rejected command records terminal"), LogCapture.CountStage(TEXT("terminal")), 1);
	TestEqual(TEXT("Impossible aim rejection emits exactly one structured event"), ObservabilitySink->GetEvents().Num(), 1);
	if (ObservabilitySink->GetEvents().Num() == 1)
	{
		const FAethelnObservabilityEvent& RejectionEvent = ObservabilitySink->GetEvents()[0];
		TestEqual(TEXT("Rejection envelope has a stable category"), RejectionEvent.Category, EAethelnObservabilityCategory::Rejection);
		TestEqual(TEXT("Rejection retains the rejected claim family"), RejectionEvent.SubjectCategory, EAethelnObservabilityCategory::Aim);
		TestEqual(TEXT("Rejection maps to the shared safe reason"), RejectionEvent.SafeReason, EAethelnSafeReason::ImpossibleAimTransition);
		TestEqual(TEXT("Rejection uses the stable ability identity"), RejectionEvent.Correlation.AbilityId, FString(TEXT("Ability.Melee.Combo1")));
		TestEqual(TEXT("Rejection retains the intent sequence"), RejectionEvent.Correlation.Sequence, static_cast<uint64>(Intent.Sequence));
		TestTrue(TEXT("Pre-activation rejection does not invent an activation identity"), RejectionEvent.Correlation.ActivationId.IsEmpty());
	}
	TestEqual(TEXT("Impossible aim rejection emits one count metric"), ObservabilitySink->GetMetrics().Num(), 1);
	if (ObservabilitySink->GetMetrics().Num() == 1)
	{
		TestEqual(TEXT("Impossible aim rejection metric uses the rejection counter"), ObservabilitySink->GetMetrics()[0].Metric, EAethelnMetricKind::RejectionCount);
		TestEqual(TEXT("Impossible aim rejection metric increments by one"), ObservabilitySink->GetMetrics()[0].Value, static_cast<int64>(1));
	}

	ObservabilitySink->SetFailWrites(true);
	Intent.Sequence = 7;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestTrue(TEXT("Failed observability sink work drains"), ObservabilitySubsystem->WaitForIdleForTests());
	TestEqual(TEXT("Sink failure cannot change the authoritative rejection"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	TestEqual(TEXT("Sink failure cannot change authoritative health"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Sink failure cannot open the attack window"), AuthorityComponent->IsAttackWindowActive());
	TestEqual(TEXT("Failed sink writes do not mutate prior evidence"), ObservabilitySink->GetEvents().Num(), 1);
	ObservabilitySink->SetFailWrites(false);
	Intent.Sequence = 1;

	const TArray<TPair<FName, EAethelnObservabilityCategory>> RejectedClaimFamilies = {
		{ TEXT("movement"), EAethelnObservabilityCategory::Movement },
		{ TEXT("aim"), EAethelnObservabilityCategory::Aim },
		{ TEXT("activation"), EAethelnObservabilityCategory::Ability },
		{ TEXT("cooldown"), EAethelnObservabilityCategory::Cooldown },
		{ TEXT("hit"), EAethelnObservabilityCategory::Hit },
		{ TEXT("dodge"), EAethelnObservabilityCategory::Dodge },
		{ TEXT("block"), EAethelnObservabilityCategory::Block },
		{ TEXT("resource"), EAethelnObservabilityCategory::Resource },
		{ TEXT("death"), EAethelnObservabilityCategory::Death },
		{ TEXT("respawn"), EAethelnObservabilityCategory::Respawn }
	};
	for (int32 Index = 0; Index < RejectedClaimFamilies.Num(); ++Index)
	{
		FAethelnSpikeScenarioProbe RejectedProbe;
		RejectedProbe.Sequence = static_cast<uint32>(100 + Index);
		RejectedProbe.Category = RejectedClaimFamilies[Index].Key;
		RejectedProbe.ClaimedMovement = FVector(100000.0f, 0.0f, 0.0f);
		RejectedProbe.ClaimedAim = -FVector::ForwardVector;
		RejectedProbe.ClaimedOutcome = RejectedProbe.Category;
		RejectedProbe.ClaimedMagnitude = 100000.0f;
		const int32 BeforeEventCount = ObservabilitySink->GetEvents().Num();
		const EAethelnSpikeAttackRejection ProbeRejection =
			AuthorityComponent->ProcessServerScenarioProbe(RejectedProbe, TEXT("client-test"));
		TestTrue(
			*FString::Printf(TEXT("%s observability dispatch drains"), *RejectedProbe.Category.ToString()),
			ObservabilitySubsystem->WaitForIdleForTests());
		TestNotEqual(
			*FString::Printf(TEXT("%s representative claim is rejected"), *RejectedProbe.Category.ToString()),
			ProbeRejection,
			EAethelnSpikeAttackRejection::None);
		TestEqual(
			*FString::Printf(TEXT("%s rejection emits one structured event"), *RejectedProbe.Category.ToString()),
			ObservabilitySink->GetEvents().Num(),
			BeforeEventCount + 1);
		if (ObservabilitySink->GetEvents().Num() == BeforeEventCount + 1)
		{
			const FAethelnObservabilityEvent& ClaimEvent = ObservabilitySink->GetEvents().Last();
			TestEqual(
				*FString::Printf(TEXT("%s rejection retains its closed-enum family"), *RejectedProbe.Category.ToString()),
				ClaimEvent.SubjectCategory,
				RejectedClaimFamilies[Index].Value);
			TestTrue(TEXT("Representative rejection excludes an activation identity"), ClaimEvent.Correlation.ActivationId.IsEmpty());
			TestTrue(TEXT("Scenario probes exclude a fabricated ability identity"), ClaimEvent.Correlation.AbilityId.IsEmpty());
		}
	}

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

	TestTrue(TEXT("All authoritative observability work drains before sink reset"), ObservabilitySubsystem->WaitForIdleForTests());
	for (const FAethelnMetricSample& Metric : ObservabilitySink->GetMetrics())
	{
		if (Metric.Metric == EAethelnMetricKind::EventCount || Metric.Metric == EAethelnMetricKind::RejectionCount)
		{
			TestEqual(TEXT("Every authority count metric increments by one"), Metric.Value, static_cast<int64>(1));
		}
	}
	ObservabilitySubsystem->ResetSink();
	Intent.Sequence = 6;
	Intent.Aim = -FVector::ForwardVector;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestTrue(TEXT("Structured-log rejection dispatch drains"), ObservabilitySubsystem->WaitForIdleForTests());
	TestEqual(
		TEXT("Normal structured-log sink observes an authoritative rejection"),
		AuthorityComponent->GetLastRejection(),
		EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	TestEqual(
		TEXT("Structured-log rejection causes no damage"),
		Target->GetHealth(),
		HealthAfterFirstActivation);
	Intent.Aim = FVector::ForwardVector;

	const float HealthBeforeDestroyedTargetRequest = Target->GetHealth();
	Target->Destroy();
	Intent.Sequence = 7;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestTrue(TEXT("Destroyed-target observability dispatch drains"), ObservabilitySubsystem->WaitForIdleForTests());
	TestEqual(TEXT("Destroyed target receives no further effect"), Target->GetHealth(), HealthBeforeDestroyedTargetRequest);

	ObservabilitySubsystem->ResetSink();
	ObservabilitySubsystem->ResetRuntimeContext();
	GameInstance->Shutdown();
	World->DestroyWorld(false);
	GEngine->DestroyWorldContext(World);
	return true;
}

#endif
