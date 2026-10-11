#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnCombatTimelineSubsystem.h"
#include "AethelnDodgeTestAbility.h"
#include "AethelnGameplayTags.h"
#include "AethelnMovementLoopbackHarness.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "Components/SkeletalMeshComponent.h"
#include "GameFramework/CharacterMovementComponent.h"
#include "GameFramework/WorldSettings.h"
#include "Misc/AutomationTest.h"
#include <limits>

/*
 * #18 P3 dodge authority (docs/dodge-and-block.md, Test Plan D7 to D16, dodge rows).
 * Every number below is a test fixture, never tuning. FDirect calls the movement
 * authority the way the server's received-move simulation does; FNet drives the real
 * CMC saved-move, packed-move and response paths through the loopback harness.
 */
namespace AethelnDodgeAuthorityTests
{
	using namespace AethelnCombatTests;
	using EResult = EAethelnActivationResult;
	using FOutcome = TPair<float, EResult>;

	const TArray<TSubclassOf<UGameplayAbility>>& DodgeAbilities()
	{
		static const TArray<TSubclassOf<UGameplayAbility>> Abilities = { UAethelnDodgeTestAbility::StaticClass(), UAethelnSeamProbeTestAbility::StaticClass() };
		return Abilities;
	}

	template <typename TAbility>
	TAbility* FindInstance(const UAethelnAbilitySystemComponent& AbilitySystem, FGameplayAbilitySpecHandle* OutHandle = nullptr)
	{
		for (const FGameplayAbilitySpec& Spec : AbilitySystem.GetActivatableAbilities())
		{
			if (TAbility* Instance = Cast<TAbility>(Spec.GetPrimaryInstance()))
			{
				if (OutHandle != nullptr) { *OutHandle = Spec.Handle; }
				return Instance;
			}
		}
		return nullptr;
	}

	struct FEffectCounter
	{
		int32 Costs = 0;
		int32 Cooldowns = 0;
		TFunction<void()> OnCost;
	};

	FDelegateHandle CountEffects(UAethelnAbilitySystemComponent& AbilitySystem, FEffectCounter& Counter)
	{
		return AbilitySystem.OnGameplayEffectAppliedDelegateToSelf.AddLambda(
			[&Counter](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
			{
				if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnEnduranceCostEffect>())
				{
					++Counter.Costs;
					if (Counter.OnCost) { const TFunction<void()> Callback = MoveTemp(Counter.OnCost); Callback(); }
				}
				if (Spec.Def != nullptr && Spec.Def->IsA<UAethelnCooldownEffect>()) { ++Counter.Cooldowns; }
			});
	}

	float Endurance(const UAethelnAbilitySystemComponent& AbilitySystem)
	{
		return AbilitySystem.GetNumericAttribute(UAethelnCombatAttributeSet::GetEnduranceAttribute());
	}

	/** Real authority world: possession, grant, ASC, timeline driver. Requests reach the PlayerState authority directly. */
	struct FDirect
	{
		FScopedCombatTestWorld World{ true };
		FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		UAethelnDodgeTestAbility* Dodge = nullptr;
		UAethelnSeamProbeTestAbility* Probe = nullptr;
		FGameplayAbilitySpecHandle Handle;
		UAethelnCombatTimelineSubsystem* Timeline = nullptr;
		TArray<FOutcome> Outcomes;
		FEffectCounter Effects;
		FDelegateHandle OutcomeHandle;
		FDelegateHandle EffectHandle;
		float NextTimeStamp = 1.0f;

		bool Init(FAutomationTestBase& Test, const TArray<TSubclassOf<UGameplayAbility>>& Abilities = DodgeAbilities())
		{
			if (!SpawnTestPlayer(Test, World, Player, Abilities)) { return false; }
			Pawn = World.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("Dodge pawn exists"), Pawn)) { return false; }
			Player.Controller->Possess(Pawn);
			Pawn->GetCharacterMovement()->DisableMovement();
			World.World->GetWorldSettings()->MaxUndilatedFrameTime = 10.0f; // fixture long frames, not a tick budget
			Dodge = FindInstance<UAethelnDodgeTestAbility>(*Player.AbilitySystem, &Handle);
			Probe = FindInstance<UAethelnSeamProbeTestAbility>(*Player.AbilitySystem);
			Timeline = World.World->GetSubsystem<UAethelnCombatTimelineSubsystem>();
			OutcomeHandle = Player.AbilitySystem->OnMovementActivationOutcome.AddLambda([this](float Stamp, EResult Result) { Outcomes.Emplace(Stamp, Result); });
			EffectHandle = CountEffects(*Player.AbilitySystem, Effects);
			if (Abilities.Contains(UAethelnDodgeTestAbility::StaticClass()) && !Test.TestNotNull(TEXT("The fixture dodge is granted"), Dodge)) { return false; }
			return Test.TestNotNull(TEXT("Authority world owns its timeline subsystem"), Timeline);
		}

		~FDirect()
		{
			if (Player.AbilitySystem != nullptr)
			{
				Player.AbilitySystem->OnMovementActivationOutcome.Remove(OutcomeHandle);
				Player.AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.Remove(EffectHandle);
			}
		}

		FAethelnDodgeStartRequest Request(bool bAllowsStart = true, uint32 Version = 1)
		{
			FAethelnDodgeStartRequest Result;
			Result.ClientTimeStamp = NextTimeStamp++;
			Result.ContentVersion = Version;
			Result.bMovementAllowsStart = bAllowsStart;
			Result.Avatar = Pawn;
			return Result;
		}

		EResult Move(bool bAllowsStart = true, uint32 Version = 1)
		{
			return Player.AbilitySystem->ProcessMovementCarriedRequest(Request(bAllowsStart, Version));
		}

		bool TryAuthorize(const FAethelnDodgeStartRequest& InRequest) { return Player.PlayerState->TryAuthorizeDodge(InRequest); }

		double Now() const { return World.World->GetTimeSeconds(); }

		/** Ticks the real world, so the timeline's post-actor pass runs. */
		void AdvanceTo(double Time) { World.World->Tick(LEVELTICK_All, static_cast<float>(Time - Now())); }

		/** Advances time only: no pass runs, so a request must apply its own due boundaries. */
		void AdvanceTimeOnlyTo(double Time) { World.World->Tick(LEVELTICK_TimeOnly, static_cast<float>(Time - Now())); }

		bool Has(const FGameplayTag& Tag) const { return Player.AbilitySystem->HasMatchingGameplayTag(Tag); }

		void ClearCooldown() { Player.AbilitySystem->RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Dodge)); }
	};

	/** The P2 loopback harness with real PlayerState authorities on both copies. */
	struct FNet
	{
		AAethelnPlayerState* ClientState = nullptr;
		AAethelnPlayerState* ServerState = nullptr;
		AethelnDodgeTests::FLoopback Pair;
		UAethelnAbilitySystemComponent* ServerAbilitySystem = nullptr;
		UAethelnDodgeTestAbility* ServerDodge = nullptr;
		TArray<FOutcome> Outcomes;
		FEffectCounter Effects;
		FDelegateHandle OutcomeHandle;
		FDelegateHandle EffectHandle;

		FNet()
			: Pair([this](APlayerController& ClientController, APlayerController& ServerController)
			{
				ClientState = AttachFreshPlayerState(*ClientController.GetWorld(), ClientController, DodgeAbilities());
				ServerState = AttachFreshPlayerState(*ServerController.GetWorld(), ServerController, DodgeAbilities());
			})
		{
		}

		~FNet()
		{
			if (ServerAbilitySystem != nullptr)
			{
				ServerAbilitySystem->OnMovementActivationOutcome.Remove(OutcomeHandle);
				ServerAbilitySystem->OnGameplayEffectAppliedDelegateToSelf.Remove(EffectHandle);
			}
		}

		bool Init(FAutomationTestBase& Test)
		{
			if (!Test.TestTrue(TEXT("Loopback roles, players and acknowledged pawns"), Pair.IsValid())
				|| !Test.TestNotNull(TEXT("Client PlayerState"), ClientState) || !Test.TestNotNull(TEXT("Server PlayerState"), ServerState))
			{
				return false;
			}
			ServerAbilitySystem = ServerState->GetAethelnAbilitySystemComponent();
			ServerDodge = FindInstance<UAethelnDodgeTestAbility>(*ServerAbilitySystem);
			OutcomeHandle = ServerAbilitySystem->OnMovementActivationOutcome.AddLambda([this](float Stamp, EResult Result) { Outcomes.Emplace(Stamp, Result); });
			EffectHandle = CountEffects(*ServerAbilitySystem, Effects);
			return Test.TestNotNull(TEXT("Server granted the dodge"), ServerDodge)
				&& Test.TestTrue(TEXT("The real PlayerState authority is used, not a test authority"), Pair.ServerMovement->TestDodgeAuthority == nullptr)
				&& Test.TestTrue(TEXT("Warm move round trip"), Pair.Warm());
		}

		/** Presses on the client and predicts the flagged move; returns the captured packet. */
		AethelnDodgeTests::FPacket PressAndPredict(FAutomationTestBase& Test)
		{
			Test.TestTrue(TEXT("The owner's local gate predicts the dodge"), Pair.ClientMovement->RequestDodge());
			Pair.Predict(FVector(1000.0f, 0.0f, 0.0f));
			return Pair.Packets.Last();
		}

		const FAethelnServerDodgeWindow& Window() const { return ServerAbilitySystem->GetDodgeWindowForTests(); }
	};

	void ExpectEvent(FAutomationTestBase& Test, const TArray<FAethelnObservabilityEvent>& Events, int32 Index,
		EAethelnObservabilityCategory Category, EAethelnObservabilityCategory Subject, EAethelnSafeReason Reason,
		uint64 Sequence, const FString& ActivationId, const FString& AbilityId)
	{
		const FString Prefix = FString::Printf(TEXT("Event %d"), Index);
		if (!Test.TestTrue(Prefix + TEXT(" exists"), Events.IsValidIndex(Index))) { return; }
		const FAethelnObservabilityEvent& Event = Events[Index];
		Test.TestEqual(Prefix + TEXT(" category"), FString(LexToString(Event.Category)), FString(LexToString(Category)));
		Test.TestEqual(Prefix + TEXT(" subject"), FString(LexToString(Event.SubjectCategory)), FString(LexToString(Subject)));
		Test.TestEqual(Prefix + TEXT(" safe reason"), FString(LexToString(Event.SafeReason)), FString(LexToString(Reason)));
		Test.TestEqual(Prefix + TEXT(" server ordinal"), static_cast<int64>(Event.Correlation.Sequence), static_cast<int64>(Sequence));
		Test.TestEqual(Prefix + TEXT(" activation id"), Event.Correlation.ActivationId, ActivationId);
		Test.TestEqual(Prefix + TEXT(" ability id"), Event.Correlation.AbilityId, AbilityId);
		Test.TestTrue(Prefix + TEXT(" public copy has no diagnostic code"), Event.DiagnosticCode == EAethelnDiagnosticCode::None);
	}

	void ExpectMetric(FAutomationTestBase& Test, const TArray<FAethelnMetricSample>& Metrics, int32 Index,
		EAethelnMetricKind Kind, EAethelnObservabilityCategory Category, EAethelnSafeReason Reason, int64 Value)
	{
		const FString Prefix = FString::Printf(TEXT("Metric %d"), Index);
		if (!Test.TestTrue(Prefix + TEXT(" exists"), Metrics.IsValidIndex(Index))) { return; }
		Test.TestEqual(Prefix + TEXT(" kind"), FString(LexToString(Metrics[Index].Metric)), FString(LexToString(Kind)));
		Test.TestEqual(Prefix + TEXT(" category"), FString(LexToString(Metrics[Index].Category)), FString(LexToString(Category)));
		Test.TestEqual(Prefix + TEXT(" reason"), FString(LexToString(Metrics[Index].Reason)), FString(LexToString(Reason)));
		Test.TestEqual(Prefix + TEXT(" value"), Metrics[Index].Value, Value);
	}

	UAethelnObservabilitySubsystem* SetSinks(FAutomationTestBase& Test, const FDirect& F,
		const TSharedPtr<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>& Sink,
		const TSharedPtr<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>& Restricted)
	{
		UAethelnObservabilitySubsystem* Subsystem = F.World.GameInstance != nullptr ? F.World.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>() : nullptr;
		if (!Test.TestNotNull(TEXT("Observability subsystem exists"), Subsystem)) { return nullptr; }
		Test.TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(EAethelnFlowKind::PrototypeAuthority,
			TEXT("run-dodge-p3-test"), TEXT("instance-dodge-p3-test"), TEXT("connection-dodge-p3-test")));
		Test.TestTrue(TEXT("Public sink is set"), Subsystem->SetTestSink(Sink));
		if (Restricted.IsValid()) { Test.TestTrue(TEXT("Restricted sink is set"), Subsystem->SetTestRestrictedSink(Restricted)); }
		return Subsystem;
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeDefinitionFailsClosedTest,
	"Aetheln.GameCombat.Defense.DodgeDefinitionFailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeDefinitionFailsClosedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	constexpr int32 ExpectedRefusals = 19;
	AddExpectedMessagePlain(TEXT("Refused to grant ability"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, ExpectedRefusals);
	const float NaN = std::numeric_limits<float>::quiet_NaN();
	const float Inf = std::numeric_limits<float>::infinity();

	// Each case changes one field of an otherwise grantable transient definition, through the base-pointer grant call.
	auto ExpectRefused = [this](const TCHAR* Case, TFunctionRef<void(UAethelnDodgeTestAbility&)> Change)
	{
		UAethelnDodgeTestAbility* Definition = NewObject<UAethelnDodgeTestAbility>(GetTransientPackage());
		TestTrue(*FString::Printf(TEXT("%s: the unchanged definition is grantable"), Case), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition, 1)));
		Change(*Definition);
		const UAethelnGameplayAbility* Base = Definition;
		TestNotNull(*FString::Printf(TEXT("%s: the base pointer reaches the specialized check"), Case), Base->FindGrantProblem());
		TestFalse(*FString::Printf(TEXT("%s is refused"), Case), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition, 1)));
	};
	auto ExpectGrantable = [this](const TCHAR* Case, TFunctionRef<void(UAethelnDodgeTestAbility&)> Change)
	{
		UAethelnDodgeTestAbility* Definition = NewObject<UAethelnDodgeTestAbility>(GetTransientPackage());
		Change(*Definition);
		TestTrue(*FString::Printf(TEXT("%s is grantable"), Case), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition, 1)));
	};

	ExpectRefused(TEXT("Non-finite distance"), [NaN](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.Distance = NaN; });
	ExpectRefused(TEXT("Non-finite move duration"), [Inf](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.MoveDuration = Inf; });
	ExpectRefused(TEXT("Non-finite invulnerable start"), [NaN](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.InvulnerableStart = NaN; });
	ExpectRefused(TEXT("Non-finite invulnerable end"), [Inf](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.InvulnerableEnd = Inf; });
	ExpectRefused(TEXT("Non-finite action end"), [NaN](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.ActionEnd = NaN; });
	ExpectRefused(TEXT("Zero distance"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.Distance = 0.0f; });
	ExpectRefused(TEXT("Negative distance"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.Distance = -1.0f; });
	ExpectRefused(TEXT("Zero move duration"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.MoveDuration = 0.0f; });
	ExpectRefused(TEXT("Negative invulnerable start"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.InvulnerableStart = -0.0625f; });
	ExpectRefused(TEXT("Empty invulnerability window"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.InvulnerableEnd = D.ProvisionalDodge.InvulnerableStart; });
	ExpectRefused(TEXT("Invulnerability beyond action end"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.InvulnerableEnd = D.ProvisionalDodge.ActionEnd + 0.0625f; });
	ExpectRefused(TEXT("Move duration beyond action end"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalDodge.MoveDuration = D.ProvisionalDodge.ActionEnd + 0.0625f; });
	ExpectRefused(TEXT("Missing movement-carried flag"), [](UAethelnDodgeTestAbility& D) { D.SetMovementCarriedForTests(false); });
	ExpectRefused(TEXT("Missing State.Dead blocking tag"), [](UAethelnDodgeTestAbility& D) { D.SetBlockedTagsForTests(FGameplayTagContainer()); });
	ExpectRefused(TEXT("Zero cost with zero cooldown (Q4)"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalEnduranceCost = 0.0f; D.ProvisionalCooldownSeconds = 0.0f; });
	ExpectRefused(TEXT("A Release route"), [](UAethelnDodgeTestAbility& D) { D.bAcceptsRelease = true; });
	ExpectRefused(TEXT("Content version 0"), [](UAethelnDodgeTestAbility& D) { D.ContentVersion = 0; });

	ExpectGrantable(TEXT("Cost without cooldown (Q4)"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalCooldownSeconds = 0.0f; });
	ExpectGrantable(TEXT("Cooldown without cost (Q4)"), [](UAethelnDodgeTestAbility& D) { D.ProvisionalEnduranceCost = 0.0f; });
	ExpectGrantable(TEXT("Window boundaries at their inclusive limits"), [](UAethelnDodgeTestAbility& D)
	{
		D.ProvisionalDodge.InvulnerableStart = 0.0f;
		D.ProvisionalDodge.InvulnerableEnd = D.ProvisionalDodge.ActionEnd;
		D.ProvisionalDodge.MoveDuration = D.ProvisionalDodge.ActionEnd;
	});

	TestFalse(TEXT("The production dodge with no authored values (TBD, #107) is refused"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnDodgeAbility::StaticClass(), 1)));

	// End to end: the real PlayerState grant path refuses the placeholder class and grants the valid one.
	FDirect F;
	if (!F.Init(*this, { UAethelnDodgeAbility::StaticClass(), UAethelnDodgeTestAbility::StaticClass() })) { return false; }
	TestEqual(TEXT("Only the valid dodge is granted"), F.Player.AbilitySystem->GetActivatableAbilities().Num(), 1);
	TestNotNull(TEXT("The valid dodge's instance exists"), F.Dodge);
	TestTrue(TEXT("The granted definition reaches movement"), F.Player.PlayerState->GetDodgeMovementDefinition().IsValid());
	TestEqual(TEXT("Movement reads the granted content version"), F.Player.PlayerState->GetDodgeMovementDefinition().ContentVersion, 1u);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeMovementCarriedRouteTest,
	"Aetheln.GameCombat.Defense.DodgeMovementCarriedRoute",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeMovementCarriedRouteTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	FDirect F;
	if (!F.Init(*this) || !TestNotNull(TEXT("Dodge instance"), F.Dodge) || !TestNotNull(TEXT("Probe instance"), F.Probe)) { return false; }
	UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
	const float StartEndurance = Endurance(ASC);

	// The ordinary RPC never reaches a movement-carried ability.
	FAethelnCombatActivationRequest Ordinary;
	Ordinary.AbilityId = AethelnGameplayTags::Ability_Dodge;
	Ordinary.ContentVersion = 1;
	Ordinary.Sequence = 1;
	FillTestAimAndTime(Ordinary, ASC);
	TestEqual(TEXT("ServerSubmitActivation for the dodge is MalformedRequest"), ASC.ProcessServerRequest(Ordinary), EResult::MalformedRequest);
	// Stock routes stay refused: the choke point opens only the movement scope for the dodge spec.
	ASC.CallServerTryActivateAbilityForTests(F.Handle);
	TestFalse(TEXT("A server-side stock activation is refused"), ASC.TryActivateAbility(F.Handle));
	TestFalse(TEXT("Activation by class is refused"), ASC.TryActivateAbilityByClass(UAethelnDodgeTestAbility::StaticClass()));
	TestFalse(TEXT("No stock or ordinary route activates the dodge"), F.Dodge->IsActive());
	TestEqual(TEXT("Stock and ordinary routes issue no movement ordinal"), ASC.GetMovementActivationOrdinalForTests(), 0u);

	// Precedence follows the substitution table: lifecycle, lookup, version, phase/instance/start.
	FAethelnDodgeStartRequest WrongAvatar = F.Request(true, 2);
	WrongAvatar.Avatar = nullptr;
	TestEqual(TEXT("Lifecycle precedes version"), ASC.ProcessMovementCarriedRequest(WrongAvatar), EResult::ConnectionClosed);
	AAethelnPlayerCharacter* Other = F.World.Spawn<AAethelnPlayerCharacter>();
	FAethelnDodgeStartRequest OtherAvatar = F.Request();
	OtherAvatar.Avatar = Other;
	TestEqual(TEXT("Only the possessed avatar's own move may ask"), ASC.ProcessMovementCarriedRequest(OtherAvatar), EResult::ConnectionClosed);
	TestEqual(TEXT("Version precedes the start predicate"), F.Move(false, 2), EResult::IncompatibleVersion);
	TestEqual(TEXT("A server-derived refusal to start is ActivationBlocked"), F.Move(false), EResult::ActivationBlocked);
	TestEqual(TEXT("Rejections spend nothing"), F.Effects.Costs + F.Effects.Cooldowns, 0);
	TestFalse(TEXT("Rejections hold no state tag"), F.Has(AethelnGameplayTags::State_Dodging));
	TestEqual(TEXT("Rejections leave Endurance"), Endurance(ASC), StartEndurance);

	// Accept, while a nested other-spec activation inside the dodge's commit stays refused.
	FGameplayAbilitySpecHandle ProbeHandle;
	FindInstance<UAethelnSeamProbeTestAbility>(ASC, &ProbeHandle);
	bool bNestedActivated = true;
	F.Effects.OnCost = [&ASC, ProbeHandle, &bNestedActivated]() { bNestedActivated = ASC.TryActivateAbility(ProbeHandle); };
	TestEqual(TEXT("The movement entry activates the dodge"), F.Move(), EResult::Accepted);
	TestFalse(TEXT("The scope opens for the dodge spec only"), bNestedActivated);
	TestTrue(TEXT("The dodge is active"), F.Dodge->IsActive());
	TestEqual(TEXT("Every call that reached the entry has an ordinal"), ASC.GetMovementActivationOrdinalForTests(), 5u);
	TestEqual(TEXT("The dodge advances no ordinary sequence"), ASC.GetLastAcceptedSequenceForTests(), 0u);
	TestTrue(TEXT("The dodge records no raw aim"), ASC.GetLastAcceptedAimForTests().IsZero());
	TestEqual(TEXT("The dodge records no client time"), ASC.GetLastAcceptedClientTimeForTests(), 0.0);
	TestEqual(TEXT("A Press while active is blocked before eligibility"), F.Move(), EResult::ActivationBlocked);

	// An ordinary seam Press right after is accepted on untouched ordinary history.
	FAethelnCombatActivationRequest ProbePress;
	ProbePress.AbilityId = AethelnCombatTestTags::Ability_Test_Probe;
	ProbePress.ContentVersion = 1;
	ProbePress.Sequence = 1;
	FillTestAimAndTime(ProbePress, ASC);
	TestEqual(TEXT("A seam Press after an accepted dodge is accepted"), ASC.ProcessServerRequest(ProbePress), EResult::Accepted);
	TestEqual(TEXT("Only ordinary acceptance advances the sequence"), ASC.GetLastAcceptedSequenceForTests(), 1u);

	// No grant: the move names no ability, so it is blocked with no ability id.
	FDirect NoDodge;
	if (!NoDodge.Init(*this, { UAethelnSeamProbeTestAbility::StaticClass() })) { return false; }
	TestEqual(TEXT("Without a granted dodge the entry is ActivationBlocked"), NoDodge.Move(), EResult::ActivationBlocked);
	TestFalse(TEXT("Without a grant movement gets no definition"), NoDodge.Player.PlayerState->GetDodgeMovementDefinition().IsValid());

	// Client-mode copy: a non-authority ASC authorizes nothing, draws no token, and sends nothing.
	FDirect Client;
	if (!Client.Init(*this)) { return false; }
	Client.Player.PlayerState->SetRole(ROLE_AutonomousProxy);
	Client.Player.AbilitySystem->CacheIsNetSimulated();
	TestFalse(TEXT("A client copy refuses"), Client.TryAuthorize(Client.Request()));
	TestEqual(TEXT("A client copy issues no ordinal"), Client.Player.AbilitySystem->GetMovementActivationOrdinalForTests(), 0u);
	TestEqual(TEXT("A client copy sends no outcome"), Client.Outcomes.Num(), 0);
	TestFalse(TEXT("A client copy registers no boundaries"), Client.Timeline->RegisterNonChainBoundaries(*Client.Player.AbilitySystem));
	TestFalse(TEXT("A client copy holds no window"), Client.Player.AbilitySystem->GetDodgeWindowForTests().bOpen);
	Client.Player.PlayerState->SetRole(ROLE_Authority);
	Client.Player.AbilitySystem->CacheIsNetSimulated();
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeCostCooldownAndRepeatsTest,
	"Aetheln.GameCombat.Defense.DodgeCostCooldownAndRepeats",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeCostCooldownAndRepeatsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	{
		FDirect F;
		if (!F.Init(*this) || !TestNotNull(TEXT("Dodge instance"), F.Dodge)) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		ASC.ProvisionalActivationBucketCapacity = 6.0f; // fixture: exactly six requests below
		const float Start = Endurance(ASC);
		TestEqual(TEXT("Accepted"), F.Move(), EResult::Accepted);
		TestEqual(TEXT("One cost"), F.Effects.Costs, 1);
		TestEqual(TEXT("One cooldown"), F.Effects.Cooldowns, 1);
		TestEqual(TEXT("Endurance drops by the fixture cost"), Endurance(ASC), Start - 5.0f);
		TestTrue(TEXT("Cooldown.Dodge is granted"), F.Has(AethelnGameplayTags::Cooldown_Dodge));
		// A replayed operation cannot commit again.
		TestFalse(TEXT("A second full commit under the same operation is refused"),
			F.Dodge->CommitAbility(F.Handle, F.Dodge->GetCurrentActorInfo(), F.Dodge->GetCurrentActivationInfo()));
		TestEqual(TEXT("During the dodge: ActivationBlocked"), F.Move(), EResult::ActivationBlocked);
		F.AdvanceTo(0.5);
		TestFalse(TEXT("The dodge ended at ActionEnd"), F.Dodge->IsActive());
		TestEqual(TEXT("During the cooldown: OnCooldown"), F.Move(), EResult::OnCooldown);
		F.ClearCooldown();
		ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Override, 1.0f);
		TestEqual(TEXT("Low Endurance: InsufficientResource"), F.Move(), EResult::InsufficientResource);
		F.Dodge->bFailCommitForTests = true;
		ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Override, 30.0f);
		TestEqual(TEXT("A failed commit: InternalFailure"), F.Move(), EResult::InternalFailure);
		TestFalse(TEXT("A failed commit opens no window"), ASC.GetDodgeWindowForTests().bOpen);
		F.Dodge->bFailCommitForTests = false;
		TestEqual(TEXT("Rejections spend nothing"), F.Effects.Costs + F.Effects.Cooldowns, 2);
		TestEqual(TEXT("Accepted again once eligible"), F.Move(), EResult::Accepted);
		TestEqual(TEXT("Each draws one token, rejections included: the seventh is rate limited"), F.Move(), EResult::RateLimited);
		TestEqual(TEXT("One outcome per request"), F.Outcomes.Num(), 7);
		TestEqual(TEXT("Two accepted dodges, two costs"), F.Effects.Costs, 2);
	}

	// Synchronous callbacks during the commit preserve operation identity.
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		EResult Nested = EResult::Accepted;
		F.Effects.OnCost = [&F, &Nested]() { Nested = F.Move(); };
		TestEqual(TEXT("The outer dodge is accepted"), F.Move(), EResult::Accepted);
		TestEqual(TEXT("A nested request during commit sees the active instance"), Nested, EResult::ActivationBlocked);
		TestEqual(TEXT("The nested request spent nothing"), F.Effects.Costs, 1);
		TestTrue(TEXT("The outer window is open"), ASC.GetDodgeWindowForTests().bOpen);
	}
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		F.Effects.OnCost = [&ASC]() { ASC.AddLooseGameplayTag(AethelnGameplayTags::State_Dead); };
		TestEqual(TEXT("Death during commit leaves no accepted dodge"), F.Move(), EResult::InternalFailure);
		TestFalse(TEXT("Death during commit opens no window"), ASC.GetDodgeWindowForTests().bOpen);
		TestFalse(TEXT("Death during commit avoids nothing"), ASC.IsAvoidingAt(F.Now() + 0.125));
		TestFalse(TEXT("Death during commit holds no state tag"), F.Has(AethelnGameplayTags::State_Dodging));
		TestFalse(TEXT("Death during commit leaves no active instance"), F.Dodge->IsActive());
	}
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		F.Effects.OnCost = [&F]() { F.Player.Controller->UnPossess(); };
		TestEqual(TEXT("Avatar loss during commit leaves no accepted dodge"), F.Move(), EResult::InternalFailure);
		TestFalse(TEXT("Avatar loss during commit opens no window"), ASC.GetDodgeWindowForTests().bOpen);
		TestFalse(TEXT("Avatar loss during commit holds no state tag"), F.Has(AethelnGameplayTags::State_Dodging));
		F.Player.Controller->Possess(F.Pawn);
		TestFalse(TEXT("Re-possession revives no window"), ASC.GetDodgeWindowForTests().bOpen);
		TestFalse(TEXT("Re-possession revives no avoidance"), ASC.IsAvoidingAt(F.Now() + 0.125));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeWindowBoundariesTest,
	"Aetheln.GameCombat.Defense.DodgeWindowBoundaries",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeWindowBoundariesTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	using namespace AethelnGameplayTags;
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		F.AdvanceTo(1.0);
		const double S = F.Now();
		FAethelnDodgeStartRequest Request = F.Request();
		Request.ClientTimeStamp = 123.0f; // a client timestamp is never a window input
		TestTrue(TEXT("Accepted"), F.TryAuthorize(Request));
		const FAethelnServerDodgeWindow& W = ASC.GetDodgeWindowForTests();
		TestEqual(TEXT("S is the server processing time"), W.StartTime, S);
		TestEqual(TEXT("Invulnerability start"), W.InvulnerableStart, S + 0.0625);
		TestEqual(TEXT("Invulnerability end"), W.InvulnerableEnd, S + 0.3125);
		TestEqual(TEXT("Action end"), W.ActionEnd, S + 0.5);
		TestFalse(TEXT("Before the start: not avoiding"), ASC.IsAvoidingAt(S + 0.0625 - 1.0e-6));
		TestTrue(TEXT("At the start: avoiding (inclusive)"), ASC.IsAvoidingAt(S + 0.0625));
		TestTrue(TEXT("Just before the end: avoiding"), ASC.IsAvoidingAt(S + 0.3125 - 1.0e-6));
		TestFalse(TEXT("At the end: not avoiding (exclusive)"), ASC.IsAvoidingAt(S + 0.3125));
		TestTrue(TEXT("State.Dodging from S"), F.Has(State_Dodging));
		TestFalse(TEXT("No invulnerability tag before its start"), F.Has(State_DodgeInvulnerable));
		TestEqual(TEXT("The non-chain timeline is registered"), F.Timeline->GetBoundaryOwnerCountForTests(), 1);
		F.AdvanceTo(S + 0.0625);
		TestTrue(TEXT("The invulnerability tag appears at its boundary"), F.Has(State_DodgeInvulnerable));
		F.AdvanceTo(S + 0.3125);
		TestFalse(TEXT("The invulnerability tag ends at its boundary"), F.Has(State_DodgeInvulnerable));
		TestTrue(TEXT("State.Dodging lasts until ActionEnd"), F.Has(State_Dodging));
		F.AdvanceTo(S + 0.5);
		TestFalse(TEXT("State.Dodging ends at ActionEnd"), F.Has(State_Dodging));
		TestFalse(TEXT("The activation ends at ActionEnd"), F.Dodge->IsActive());
		TestEqual(TEXT("Withheld moves neither extend nor shorten the window"), W.InvulnerableEnd, S + 0.3125);
		TestEqual(TEXT("No boundary owner remains"), F.Timeline->GetBoundaryOwnerCountForTests(), 0);
	}
	// Due boundaries apply before validation, at exactly S + ActionEnd and not before.
	for (const bool bAtActionEnd : { false, true })
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		F.Dodge->ProvisionalCooldownSeconds = 0.0f; // fixture: isolate the dodge's own action end (Q4 still holds via cost)
		TestEqual(TEXT("First dodge"), F.Move(), EResult::Accepted);
		const double S = F.Now();
		F.AdvanceTimeOnlyTo(S + (bAtActionEnd ? 0.5 : 0.5 - 0.015625));
		TestTrue(TEXT("No pass ran: the instance is still active"), F.Dodge->IsActive());
		TestEqual(TEXT("A request at S + ActionEnd is not blocked by the dodge; before it, it is"),
			F.Move(), bAtActionEnd ? EResult::Accepted : EResult::ActivationBlocked);
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeEndToEndTest,
	"Aetheln.GameCombat.Defense.DodgeEndToEnd",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeEndToEndTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	using AethelnDodgeTests::PositionTolerance;
	FNet N;
	if (!N.Init(*this)) { return false; }
	const float StartX = N.Pair.Server->GetActorLocation().X;
	const AethelnDodgeTests::FPacket First = N.PressAndPredict(*this);
	TestTrue(TEXT("The flagged move reaches the real handler"), N.Pair.Deliver(First));
	TestTrue(TEXT("The server started the displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
	TestTrue(TEXT("The server window is open"), N.Window().bOpen);
	for (int32 Step = 0; Step < 10; ++Step) { N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); }
	TestEqual(TEXT("An accepted dodge produces no correction"), N.Pair.CorrectionCount, 0);
	TestTrue(TEXT("The client followed the server path"), N.Pair.Client->GetActorLocation().Equals(N.Pair.Server->GetActorLocation(), PositionTolerance));
	TestTrue(TEXT("The server moved the fixture distance"), FMath::IsNearlyEqual(N.Pair.Server->GetActorLocation().X - StartX, 120.0f, 1.0f));

	// After ActionEnd but inside the cooldown, the stale owner gate predicts and the server refuses.
	for (int32 Step = 0; Step < 6; ++Step) { N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); }
	const AethelnDodgeTests::FPacket Second = N.PressAndPredict(*this);
	TestTrue(TEXT("The refused flagged move reaches the handler"), N.Pair.Deliver(Second));
	TestEqual(TEXT("A refused prediction rolls back with one correction"), N.Pair.CorrectionCount, 1);
	TestFalse(TEXT("The client no longer predicts the refused dodge"), N.Pair.ClientMovement->GetDodgeState().bInProgress);
	for (int32 Step = 0; Step < 3; ++Step) { N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); }
	TestEqual(TEXT("No further correction"), N.Pair.CorrectionCount, 1);
	TestTrue(TEXT("The client converged on the server"), N.Pair.Client->GetActorLocation().Equals(N.Pair.Server->GetActorLocation(), PositionTolerance));
	if (TestEqual(TEXT("One outcome per flagged move"), N.Outcomes.Num(), 2))
	{
		TestEqual(TEXT("First outcome keyed by its move timestamp"), N.Outcomes[0].Key, First.NewTimeStamp);
		TestEqual(TEXT("First outcome"), N.Outcomes[0].Value, EResult::Accepted);
		TestEqual(TEXT("Second outcome keyed by its move timestamp"), N.Outcomes[1].Key, Second.NewTimeStamp);
		TestEqual(TEXT("Second outcome"), N.Outcomes[1].Value, EResult::OnCooldown);
	}
	TestEqual(TEXT("One commit"), N.Effects.Costs, 1);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnNetworkConditionsDodgeTest,
	"Aetheln.GameCombat.Defense.NetworkConditionsDodge",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnNetworkConditionsDodgeTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	// Normal and high latency, each with a duplicated copy and an older reordered copy.
	for (const bool bDelay : { false, true })
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		const AethelnDodgeTests::FPacket Start = N.PressAndPredict(*this);
		if (bDelay) { N.Pair.World->Tick(LEVELTICK_TimeOnly, 0.125f); } // fixture latency
		const double Arrival = N.Pair.World->GetTimeSeconds();
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(Start));
		TestEqual(TEXT("The window starts at server arrival"), N.Window().StartTime, Arrival);
		N.Pair.Deliver(Start, false);
		N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); N.Pair.Deliver(Start, false);
		TestEqual(TEXT("Positive control: warm, start, successor simulated"), N.Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Duplicate and reordered copies never reach the authority"), N.ServerAbilitySystem->GetMovementActivationOrdinalForTests(), 1u);
		TestEqual(TEXT("One commit, no double cost"), N.Effects.Costs, 1);
		TestEqual(TEXT("One cooldown"), N.Effects.Cooldowns, 1);
		TestEqual(TEXT("One outcome"), N.Outcomes.Num(), 1);
	}
	// Packet loss: the lost first copy is processed once from the engine's old-move resend.
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		const AethelnDodgeTests::FPacket Lost = N.PressAndPredict(*this);
		N.Pair.Predict(); N.Pair.Predict();
		TestTrue(TEXT("The engine resends the flagged move as the old move"), N.Pair.Packets.Last().bHasOld && N.Pair.Packets.Last().OldTimeStamp == Lost.NewTimeStamp);
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(N.Pair.Packets.Last()));
		N.Pair.Deliver(Lost, false);
		TestEqual(TEXT("Positive control: warm, old, new"), N.Pair.ServerMovement->TestReceivedMoveCount, 3);
		TestEqual(TEXT("Committed once"), N.Effects.Costs, 1);
		if (TestEqual(TEXT("One outcome"), N.Outcomes.Num(), 1)) { TestEqual(TEXT("Keyed by the resent move"), N.Outcomes[0].Key, Lost.NewTimeStamp); }
	}
	// All copies lost: nothing commits, no outcome; the next outcome resolves it as never simulated.
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		const AethelnDodgeTests::FPacket Lost = N.PressAndPredict(*this);
		N.Pair.Predict();
		TestFalse(TEXT("The first successor carries no old move"), N.Pair.Packets.Last().bHasOld);
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(N.Pair.Packets.Last()));
		TestEqual(TEXT("Positive control: warm and successor"), N.Pair.ServerMovement->TestReceivedMoveCount, 2);
		TestEqual(TEXT("No authority call"), N.ServerAbilitySystem->GetMovementActivationOrdinalForTests(), 0u);
		TestEqual(TEXT("No outcome"), N.Outcomes.Num(), 0);
		TestEqual(TEXT("Nothing committed"), N.Effects.Costs, 0);
		TestFalse(TEXT("The correction undoes the prediction"), N.Pair.ClientMovement->GetDodgeState().bInProgress);
		const AethelnDodgeTests::FPacket Next = N.PressAndPredict(*this);
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(Next));
		if (TestEqual(TEXT("The next outcome arrives"), N.Outcomes.Num(), 1))
		{
			TestTrue(TEXT("It names only the later move, so the lost one was never simulated"), N.Outcomes[0].Key == Next.NewTimeStamp && Next.NewTimeStamp != Lost.NewTimeStamp);
		}
	}
	// Unacknowledged pawn: timestamp consumed, nothing simulated or asked.
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		const AethelnDodgeTests::FPacket Start = N.PressAndPredict(*this);
		N.Pair.ServerController->AcknowledgedPawn = nullptr;
		N.Pair.Deliver(Start, false);
		TestEqual(TEXT("Positive control: only warm simulated"), N.Pair.ServerMovement->TestReceivedMoveCount, 1);
		TestEqual(TEXT("No authority call"), N.ServerAbilitySystem->GetMovementActivationOrdinalForTests(), 0u);
		N.Pair.ServerController->AcknowledgedPawn = N.Pair.Server;
	}
	// Refused for cooldown, then silence: one token, one outcome, nothing after the cooldown lapses.
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		N.ServerAbilitySystem->ProvisionalActivationBucketCapacity = 1.0f; // fixture: exactly one token
		N.ServerAbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::Cooldown_Dodge);
		const AethelnDodgeTests::FPacket Start = N.PressAndPredict(*this);
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(Start));
		N.Pair.ServerMovement->ForcePositionUpdate(AethelnDodgeTests::StepSeconds);
		N.Pair.ServerMovement->ForcePositionUpdate(AethelnDodgeTests::StepSeconds);
		N.ServerAbilitySystem->RemoveLooseGameplayTag(AethelnGameplayTags::Cooldown_Dodge);
		N.Pair.ServerMovement->ForcePositionUpdate(AethelnDodgeTests::StepSeconds);
		TestEqual(TEXT("Positive control: warm and start simulated"), N.Pair.ServerMovement->TestReceivedMoveCount, 2);
		TestEqual(TEXT("Forced updates never re-ask"), N.ServerAbilitySystem->GetMovementActivationOrdinalForTests(), 1u);
		if (TestEqual(TEXT("One outcome"), N.Outcomes.Num(), 1)) { TestEqual(TEXT("Refused for cooldown"), N.Outcomes[0].Value, EResult::OnCooldown); }
		TestEqual(TEXT("Nothing commits"), N.Effects.Costs + N.Effects.Cooldowns, 0);
		TestFalse(TEXT("No server displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
		// Moves inside the forced interval are dropped by the engine; send past it before the next press.
		for (int32 Step = 0; Step < 4; ++Step) { N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); }
		N.Pair.Deliver(N.PressAndPredict(*this));
		if (TestEqual(TEXT("The next flagged move reaches the authority"), N.Outcomes.Num(), 2))
		{
			TestEqual(TEXT("The refused move drew the only token"), N.Outcomes.Last().Value, EResult::RateLimited);
		}
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnLifeStateCancelsDodgeTest,
	"Aetheln.GameCombat.Defense.LifeStateCancelsDefense",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnLifeStateCancelsDodgeTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	FNet N;
	if (!N.Init(*this)) { return false; }
	TestTrue(TEXT("Delivered"), N.Pair.Deliver(N.PressAndPredict(*this)));
	N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last());
	N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last());
	TestTrue(TEXT("Mid-dodge on the server"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
	const double DeathTime = N.Pair.World->GetTimeSeconds();
	TestTrue(TEXT("Inside the invulnerability window before death"), N.ServerAbilitySystem->IsAvoidingAt(DeathTime));

	N.ServerAbilitySystem->AddLooseGameplayTag(AethelnGameplayTags::State_Dead); // test seam until #21
	TestFalse(TEXT("State.Dead closes the window"), N.Window().bOpen);
	TestEqual(TEXT("The window ends at the processing time"), N.Window().InvulnerableEnd, DeathTime);
	TestTrue(TEXT("An earlier contact time stays avoided"), N.ServerAbilitySystem->IsAvoidingAt(N.Window().InvulnerableStart));
	TestFalse(TEXT("No avoidance from the death time"), N.ServerAbilitySystem->IsAvoidingAt(DeathTime));
	TestFalse(TEXT("State.Dead ends the server displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
	TestFalse(TEXT("State.Dead ends the activation"), N.ServerDodge->IsActive());
	TestFalse(TEXT("No dodging tag"), N.ServerAbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_Dodging));
	TestFalse(TEXT("No invulnerability tag"), N.ServerAbilitySystem->HasMatchingGameplayTag(AethelnGameplayTags::State_DodgeInvulnerable));

	N.ServerAbilitySystem->RemoveActiveEffectsWithGrantedTags(FGameplayTagContainer(AethelnGameplayTags::Cooldown_Dodge)); // isolate State.Dead
	for (int32 Step = 0; Step < 10; ++Step) { N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last()); }
	N.Pair.Deliver(N.PressAndPredict(*this));
	TestEqual(TEXT("A later dodge while dead is ActivationBlocked"), N.Outcomes.Last().Value, EResult::ActivationBlocked);
	TestEqual(TEXT("Nothing more commits"), N.Effects.Costs, 1);

	N.ServerAbilitySystem->RemoveLooseGameplayTag(AethelnGameplayTags::State_Dead);
	N.Pair.ServerController->UnPossess();
	N.Pair.ServerController->Possess(N.Pair.Server);
	TestFalse(TEXT("Re-possession revives no window"), N.Window().bOpen);
	TestFalse(TEXT("Re-possession revives no invulnerability"), N.ServerAbilitySystem->IsAvoidingAt(N.Pair.World->GetTimeSeconds()));
	TestFalse(TEXT("Re-possession resumes no displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnTeardownMidDodgeTest,
	"Aetheln.GameCombat.Defense.TeardownMidDodgeAndBlock",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnTeardownMidDodgeTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	enum class ECase : uint8 { Unpossess, DestroyAvatar, DestroyPlayerState };
	for (const ECase Case : { ECase::Unpossess, ECase::DestroyAvatar, ECase::DestroyPlayerState })
	{
		FNet N;
		if (!N.Init(*this)) { return false; }
		TestTrue(TEXT("Delivered"), N.Pair.Deliver(N.PressAndPredict(*this)));
		N.Pair.Predict(); N.Pair.Deliver(N.Pair.Packets.Last());
		int32 Ends = 0;
		const FDelegateHandle EndHandle = N.ServerAbilitySystem->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dodging, EGameplayTagEventType::NewOrRemoved)
			.AddLambda([&Ends](const FGameplayTag, int32 Count) { Ends += Count == 0 ? 1 : 0; });
		const double Time = N.Pair.World->GetTimeSeconds();
		if (Case == ECase::Unpossess) { N.Pair.ServerController->UnPossess(); }
		if (Case == ECase::DestroyAvatar) { N.Pair.Server->Destroy(); }
		if (Case == ECase::DestroyPlayerState) { N.ServerState->Destroy(); }
		TestEqual(TEXT("One end"), Ends, 1);
		TestFalse(TEXT("No window afterwards"), N.Window().bOpen);
		TestFalse(TEXT("No avoidance afterwards"), N.ServerAbilitySystem->IsAvoidingAt(Time));
		if (Case != ECase::DestroyAvatar)
		{
			TestFalse(TEXT("The cancel path ends the server displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
		}
		N.ServerAbilitySystem->RegisterGameplayTagEvent(AethelnGameplayTags::State_Dodging, EGameplayTagEventType::NewOrRemoved).Remove(EndHandle);
		if (Case == ECase::Unpossess)
		{
			N.Pair.ServerController->Possess(N.Pair.Server);
			TestFalse(TEXT("Re-possession resumes no displacement"), N.Pair.ServerMovement->GetDodgeState().bInProgress);
			TestFalse(TEXT("Re-possession revives no window"), N.Window().bOpen);
		}
	}
	FDirect Fresh;
	if (!Fresh.Init(*this)) { return false; }
	TestFalse(TEXT("A new PlayerState starts with no window"), Fresh.Player.AbilitySystem->GetDodgeWindowForTests().bOpen);
	TestEqual(TEXT("A new PlayerState starts its ordinal at 0"), Fresh.Player.AbilitySystem->GetMovementActivationOrdinalForTests(), 0u);
	TestEqual(TEXT("A new PlayerState's first dodge is accepted"), Fresh.Move(), EResult::Accepted);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeTelemetryTest,
	"Aetheln.GameCombat.Defense.DodgeTelemetry",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeTelemetryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	using ECategory = EAethelnObservabilityCategory;
	using EReason = EAethelnSafeReason;
	using EMetric = EAethelnMetricKind;
	const FString AbilityId = AethelnGameplayTags::Ability_Dodge.GetTag().ToString();
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		auto Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
		auto Restricted = MakeShared<FAethelnBoundedRestrictedAuditSink, ESPMode::ThreadSafe>(64);
		UAethelnObservabilitySubsystem* Subsystem = SetSinks(*this, F, Sink, Restricted);
		if (Subsystem == nullptr) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		TestEqual(TEXT("Accepted"), F.Move(), EResult::Accepted);
		const FString ActivationId = F.Dodge->GetActivationId().ToString(EGuidFormats::DigitsWithHyphensLower);
		TestEqual(TEXT("Step 6"), F.Move(true, 2), EResult::IncompatibleVersion);
		TestEqual(TEXT("Step 7"), F.Move(), EResult::ActivationBlocked);
		FAethelnDodgeStartRequest Orphan = F.Request();
		Orphan.Avatar = nullptr;
		TestEqual(TEXT("Step 2"), ASC.ProcessMovementCarriedRequest(Orphan), EResult::ConnectionClosed);
		F.AdvanceTimeOnlyTo(0.5); // the request applies its own due ActionEnd boundary
		TestEqual(TEXT("Cooldown"), F.Move(), EResult::OnCooldown);
		F.ClearCooldown();
		ApplyInstantModifier(ASC, UAethelnCombatAttributeSet::GetEnduranceAttribute(), EGameplayModOp::Override, 1.0f);
		TestEqual(TEXT("Resource"), F.Move(), EResult::InsufficientResource);
		TestTrue(TEXT("Dispatch drains"), Subsystem->WaitForIdleForTests());
		// A world tick also emits server lifecycle and health records; keep only the action subjects.
		auto IsAction = [](ECategory Subject) { return Subject == ECategory::Dodge || Subject == ECategory::Cooldown || Subject == ECategory::Resource; };
		const TArray<FAethelnObservabilityEvent> Events = Sink->GetEvents().FilterByPredicate([&IsAction](const FAethelnObservabilityEvent& Event) { return IsAction(Event.SubjectCategory); });
		TestEqual(TEXT("One event per outcome"), Events.Num(), 6);
		ExpectEvent(*this, Events, 0, ECategory::Dodge, ECategory::Dodge, EReason::Accepted, 1, ActivationId, AbilityId);
		ExpectEvent(*this, Events, 1, ECategory::Rejection, ECategory::Dodge, EReason::IncompatibleVersion, 2, FString(), AbilityId);
		ExpectEvent(*this, Events, 2, ECategory::Rejection, ECategory::Dodge, EReason::ActivationBlocked, 3, FString(), AbilityId);
		ExpectEvent(*this, Events, 3, ECategory::Rejection, ECategory::Dodge, EReason::ConnectionClosed, 4, FString(), FString());
		ExpectEvent(*this, Events, 4, ECategory::Rejection, ECategory::Cooldown, EReason::ActivationBlocked, 5, FString(), AbilityId);
		ExpectEvent(*this, Events, 5, ECategory::Rejection, ECategory::Resource, EReason::ActivationBlocked, 6, FString(), AbilityId);
		const TArray<FAethelnMetricSample> Metrics = Sink->GetMetrics().FilterByPredicate([&IsAction](const FAethelnMetricSample& Metric) { return IsAction(Metric.Category); });
		TestEqual(TEXT("One metric per outcome"), Metrics.Num(), 6);
		ExpectMetric(*this, Metrics, 0, EMetric::EventCount, ECategory::Dodge, EReason::Accepted, 1);
		ExpectMetric(*this, Metrics, 1, EMetric::RejectionCount, ECategory::Dodge, EReason::IncompatibleVersion, 1);
		ExpectMetric(*this, Metrics, 4, EMetric::RejectionCount, ECategory::Cooldown, EReason::ActivationBlocked, 1);
		ExpectMetric(*this, Metrics, 5, EMetric::RejectionCount, ECategory::Resource, EReason::ActivationBlocked, 1);
		const TArray<FAethelnObservabilityEvent> RestrictedEvents = Restricted->GetEvents().FilterByPredicate([&IsAction](const FAethelnObservabilityEvent& Event) { return IsAction(Event.SubjectCategory); });
		if (TestEqual(TEXT("The restricted channel receives the same events"), RestrictedEvents.Num(), Events.Num()))
		{
			TestTrue(TEXT("The restricted copy keeps the rejection diagnostic"), RestrictedEvents[1].DiagnosticCode == EAethelnDiagnosticCode::ValidationFailed);
		}
		TestEqual(TEXT("One owner outcome per request"), F.Outcomes.Num(), 6);
		Subsystem->ResetSink();
		Subsystem->ResetRestrictedSink();
		Subsystem->ResetRuntimeContext();
	}
	// A mixed movement, ordinary and stock flood shares one bucket and one limited window.
	{
		FDirect F;
		if (!F.Init(*this)) { return false; }
		auto Sink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
		UAethelnObservabilitySubsystem* Subsystem = SetSinks(*this, F, Sink, nullptr);
		if (Subsystem == nullptr) { return false; }
		UAethelnAbilitySystemComponent& ASC = *F.Player.AbilitySystem;
		ASC.ProvisionalActivationBucketCapacity = 1.0f; // fixture: one token, no refill
		TArray<TPair<uint32, EResult>> OrdinaryOutcomes;
		const FDelegateHandle OrdinaryHandle = ASC.OnActivationOutcome.AddLambda([&OrdinaryOutcomes](uint32 Sequence, EResult Result) { OrdinaryOutcomes.Emplace(Sequence, Result); });
		TestEqual(TEXT("The only token"), F.Move(), EResult::Accepted);
		for (int32 Index = 0; Index < 3; ++Index) { TestEqual(TEXT("Movement flood"), F.Move(), EResult::RateLimited); }
		FAethelnCombatActivationRequest Ordinary;
		Ordinary.AbilityId = AethelnCombatTestTags::Ability_Test_Probe;
		Ordinary.ContentVersion = 1;
		FillTestAimAndTime(Ordinary, ASC);
		for (uint32 Sequence = 1; Sequence <= 2; ++Sequence) { Ordinary.Sequence = Sequence; TestEqual(TEXT("Ordinary flood"), ASC.ProcessServerRequest(Ordinary), EResult::RateLimited); }
		for (int32 Index = 0; Index < 2; ++Index) { ASC.CallServerTryActivateAbilityForTests(F.Handle); }
		ASC.ProvisionalActivationBucketRefillPerSecond = 1.0f;
		F.World.World->RealTimeSeconds += 1.0;
		TestEqual(TEXT("Admitted after the window"), F.Move(), EResult::ActivationBlocked);
		TestTrue(TEXT("Dispatch drains"), Subsystem->WaitForIdleForTests());
		TestEqual(TEXT("Events: accepted, one entry, the admitted one"), Sink->GetEvents().Num(), 3);
		ExpectEvent(*this, Sink->GetEvents(), 1, ECategory::Rejection, ECategory::Dodge, EReason::RateLimited, 2, FString(), FString());
		ExpectEvent(*this, Sink->GetEvents(), 2, ECategory::Rejection, ECategory::Dodge, EReason::ActivationBlocked, 5, FString(), AbilityId);
		TestEqual(TEXT("Metrics: accepted, entry, aggregated exit, admitted"), Sink->GetMetrics().Num(), 4);
		ExpectMetric(*this, Sink->GetMetrics(), 1, EMetric::RejectionCount, ECategory::Dodge, EReason::RateLimited, 1);
		ExpectMetric(*this, Sink->GetMetrics(), 2, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 6);
		if (TestEqual(TEXT("Movement outcomes: accepted, one entry, admitted"), F.Outcomes.Num(), 3))
		{
			TestEqual(TEXT("The movement entry gets the typed outcome"), F.Outcomes[1].Value, EResult::RateLimited);
		}
		TestEqual(TEXT("Ordinary requests inside the window get no outcome"), OrdinaryOutcomes.Num(), 0);
		ASC.OnActivationOutcome.Remove(OrdinaryHandle);

		// Teardown while limited flushes the exit metric.
		ASC.ProvisionalActivationBucketRefillPerSecond = 0.0f;
		TestEqual(TEXT("Enters again"), F.Move(), EResult::RateLimited);
		TestEqual(TEXT("Suppressed"), F.Move(), EResult::RateLimited);
		auto TeardownSink = MakeShared<FAethelnInMemoryObservabilitySink, ESPMode::ThreadSafe>(64);
		TestTrue(TEXT("Teardown sink is set"), Subsystem->SetTestSink(TeardownSink));
		F.Player.Controller->Destroy();
		TestTrue(TEXT("Teardown dispatch drains"), Subsystem->WaitForIdleForTests());
		if (TestEqual(TEXT("Teardown flushes one exit metric"), TeardownSink->GetMetrics().Num(), 1))
		{
			ExpectMetric(*this, TeardownSink->GetMetrics(), 0, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 1);
		}
		Subsystem->ResetSink();
		Subsystem->ResetRuntimeContext();
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(FAethelnDodgeWithoutPresentationTest,
	"Aetheln.GameCombat.Defense.RunsWithoutPresentation",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnDodgeWithoutPresentationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnDodgeAuthorityTests;
	FDirect F;
	if (!F.Init(*this)) { return false; }
	TestNull(TEXT("No mesh asset"), F.Pawn->GetMesh()->GetSkeletalMeshAsset());
	TestEqual(TEXT("A dodge runs with no mesh, montage or notify"), F.Move(), EResult::Accepted);
	const double S = F.Now();
	TestTrue(TEXT("The authored window holds"), F.Player.AbilitySystem->IsAvoidingAt(S + 0.0625));
	F.AdvanceTo(S + 0.5);
	TestFalse(TEXT("The server timeline ends it without animation"), F.Dodge->IsActive());
	TestFalse(TEXT("No state tag remains"), F.Has(AethelnGameplayTags::State_Dodging));
	return true;
}

#endif
