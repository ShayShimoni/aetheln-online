#if WITH_DEV_AUTOMATION_TESTS

#include "AbilitySystemGlobals.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnActivationTypes.h"
#include "AethelnCombatTestAbilities.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnGameplayAbility.h"
#include "AethelnObservability.h"
#include "AethelnObservabilitySubsystem.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "GameFramework/PlayerController.h"
#include "HAL/IConsoleManager.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"
#include "UObject/UnrealType.h"
#include <limits>

namespace AethelnActivationSeamTests
{
	using AethelnCombatTests::FScopedCombatTestWorld;
	using AethelnCombatTests::FTestPlayer;
	using AethelnCombatTests::SpawnTestPlayer;
	using EResult = EAethelnActivationResult;
	using EPhase = EAethelnActivationPhase;

	FString ResultName(EAethelnActivationResult Result)
	{
		return StaticEnum<EAethelnActivationResult>()->GetNameStringByValue(static_cast<int64>(Result));
	}

	void ExpectResult(FAutomationTestBase& Test, const FString& What, EAethelnActivationResult Actual, EAethelnActivationResult Expected)
	{
		Test.TestEqual(What, ResultName(Actual), ResultName(Expected));
	}

	/** A possessed player whose PlayerState granted the seam probe and the long-running test ability. */
	struct FSeamFixture
	{
		FTestPlayer Player;
		AAethelnPlayerCharacter* Pawn = nullptr;
		UAethelnSeamProbeTestAbility* Probe = nullptr;
		FGameplayAbilitySpecHandle ProbeHandle;
		FGameplayAbilitySpecHandle LongRunningHandle;
		TArray<TPair<uint32, EAethelnActivationResult>> Outcomes;

		bool Init(FAutomationTestBase& Test, const FScopedCombatTestWorld& TestWorld)
		{
			if (!SpawnTestPlayer(Test, TestWorld, Player, { UAethelnSeamProbeTestAbility::StaticClass(), UAethelnLongRunningTestAbility::StaticClass() }))
			{
				return false;
			}
			Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
			if (!Test.TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
			{
				return false;
			}
			Player.Controller->Possess(Pawn);
			for (const FGameplayAbilitySpec& Spec : Player.AbilitySystem->GetActivatableAbilities())
			{
				if (UAethelnSeamProbeTestAbility* Instance = Cast<UAethelnSeamProbeTestAbility>(Spec.GetPrimaryInstance()))
				{
					Probe = Instance;
					ProbeHandle = Spec.Handle;
				}
				else if (Spec.Ability != nullptr && Spec.Ability->IsA<UAethelnLongRunningTestAbility>())
				{
					LongRunningHandle = Spec.Handle;
				}
			}
			Player.AbilitySystem->OnActivationOutcome.AddLambda([this](uint32 Sequence, EAethelnActivationResult Result)
			{
				Outcomes.Emplace(Sequence, Result);
			});
			return Test.TestNotNull(TEXT("Probe instance is granted"), Probe)
				&& Test.TestTrue(TEXT("Long-running test ability is granted"), LongRunningHandle.IsValid());
		}

		EAethelnActivationResult Submit(
			uint32 Sequence,
			const FGameplayTag& AbilityId,
			EAethelnActivationPhase Phase = EAethelnActivationPhase::Press,
			uint32 ContentVersion = 1,
			uint8 SchemaVersion = AethelnActivation::SchemaVersion) const
		{
			FAethelnCombatActivationRequest Request;
			Request.SchemaVersion = SchemaVersion;
			Request.AbilityId = AbilityId;
			Request.ContentVersion = ContentVersion;
			Request.Phase = Phase;
			Request.Sequence = Sequence;
			AethelnCombatTests::FillTestAimAndTime(Request, *Player.AbilitySystem);
			return Player.AbilitySystem->ProcessServerRequest(Request);
		}

		bool IsActive(FGameplayAbilitySpecHandle Handle) const
		{
			const FGameplayAbilitySpec* Spec = Player.AbilitySystem->FindAbilitySpecFromHandle(Handle);
			return Spec != nullptr && Spec->IsActive();
		}

		bool HasProbeStateTag() const
		{
			return Player.AbilitySystem->HasMatchingGameplayTag(AethelnCombatTestTags::Test_ProbeActive);
		}
	};

	FGameplayTag ProbeId()
	{
		return AethelnCombatTestTags::Ability_Test_Probe;
	}

	FGameplayTag LongRunningId()
	{
		return AethelnCombatTestTags::Ability_Test_LongRunning;
	}

	FString ActivationIdString(const FGuid& ActivationId)
	{
		return ActivationId.ToString(EGuidFormats::DigitsWithHyphensLower);
	}

	void ExpectEvent(
		FAutomationTestBase& Test,
		const TArray<FAethelnObservabilityEvent>& Events,
		int32 Index,
		EAethelnObservabilityCategory Category,
		EAethelnObservabilityCategory Subject,
		EAethelnSafeReason Reason,
		uint64 Sequence,
		const FString& ActivationId,
		const FString& AbilityId)
	{
		const FString Prefix = FString::Printf(TEXT("Event %d"), Index);
		if (!Test.TestTrue(Prefix + TEXT(" exists"), Events.IsValidIndex(Index)))
		{
			return;
		}
		const FAethelnObservabilityEvent& Event = Events[Index];
		Test.TestEqual(Prefix + TEXT(" category"), FString(LexToString(Event.Category)), FString(LexToString(Category)));
		Test.TestEqual(Prefix + TEXT(" subject"), FString(LexToString(Event.SubjectCategory)), FString(LexToString(Subject)));
		Test.TestEqual(Prefix + TEXT(" safe reason"), FString(LexToString(Event.SafeReason)), FString(LexToString(Reason)));
		Test.TestEqual(Prefix + TEXT(" sequence"), static_cast<int64>(Event.Correlation.Sequence), static_cast<int64>(Sequence));
		Test.TestEqual(Prefix + TEXT(" activation id"), Event.Correlation.ActivationId, ActivationId);
		Test.TestEqual(Prefix + TEXT(" ability id"), Event.Correlation.AbilityId, AbilityId);
		Test.TestEqual(Prefix + TEXT(" connection pseudonym is excluded"), Event.Correlation.ConnectionPseudonym, FString(AethelnObservability::ExcludedIdentifier));
		Test.TestTrue(Prefix + TEXT(" public copy has no diagnostic code"), Event.DiagnosticCode == EAethelnDiagnosticCode::None);
	}

	void ExpectMetric(
		FAutomationTestBase& Test,
		const TArray<FAethelnMetricSample>& Metrics,
		int32 Index,
		EAethelnMetricKind Kind,
		EAethelnObservabilityCategory Category,
		EAethelnSafeReason Reason,
		int64 Value)
	{
		const FString Prefix = FString::Printf(TEXT("Metric %d"), Index);
		if (!Test.TestTrue(Prefix + TEXT(" exists"), Metrics.IsValidIndex(Index)))
		{
			return;
		}
		const FAethelnMetricSample& Metric = Metrics[Index];
		Test.TestEqual(Prefix + TEXT(" kind"), FString(LexToString(Metric.Metric)), FString(LexToString(Kind)));
		Test.TestEqual(Prefix + TEXT(" category"), FString(LexToString(Metric.Category)), FString(LexToString(Category)));
		Test.TestEqual(Prefix + TEXT(" reason"), FString(LexToString(Metric.Reason)), FString(LexToString(Reason)));
		Test.TestEqual(Prefix + TEXT(" value"), Metric.Value, Value);
	}

	using FOutcome = TPair<uint32, EAethelnActivationResult>;

	void ExpectOutcomes(FAutomationTestBase& Test, const FString& What, const TArray<FOutcome>& Actual, const TArray<FOutcome>& Expected)
	{
		auto Describe = [](const TArray<FOutcome>& Outcomes)
		{
			TArray<FString> Parts;
			for (const FOutcome& Outcome : Outcomes)
			{
				Parts.Add(FString::Printf(TEXT("%u:%s"), Outcome.Key, *ResultName(Outcome.Value)));
			}
			return FString::Join(Parts, TEXT(","));
		};
		Test.TestEqual(What, Describe(Actual), Describe(Expected));
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationRequestShapeTest,
	"Aetheln.GameCombat.ActivationSeam.RequestShape",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationRequestShapeTest::RunTest(const FString& Parameters)
{
	const UScriptStruct* RequestStruct = FAethelnCombatActivationRequest::StaticStruct();
	if (!TestNotNull(TEXT("Request schema exists"), RequestStruct))
	{
		return false;
	}

	TArray<FString> FieldNames;
	for (TFieldIterator<FProperty> PropertyIt(RequestStruct, EFieldIteratorFlags::IncludeSuper); PropertyIt; ++PropertyIt)
	{
		const FProperty* Property = *PropertyIt;
		FieldNames.Add(Property->GetName());
		const FString Name = Property->GetName().ToLower();
		const FString Type = Property->GetCPPType().ToLower();
		for (const TCHAR* Forbidden : { TEXT("target"), TEXT("hit"), TEXT("contact"), TEXT("damage"), TEXT("magnitude"), TEXT("attribute"), TEXT("aim"), TEXT("cost"), TEXT("cooldown"), TEXT("shape"), TEXT("range"), TEXT("window") })
		{
			const bool bAllowedAim = Name == TEXT("aim") && FString(Forbidden) == TEXT("aim");
			TestFalse(*FString::Printf(TEXT("Field %s is not named %s"), *Property->GetName(), Forbidden), !bAllowedAim && Name.Contains(Forbidden));
			TestFalse(*FString::Printf(TEXT("Field %s is not typed %s"), *Property->GetName(), Forbidden), Type.Contains(Forbidden));
		}
		TestNull(*FString::Printf(TEXT("Field %s references no object"), *Property->GetName()), CastField<FObjectPropertyBase>(Property));
	}
	TestEqual(TEXT("Request has exactly seven reflected fields"), FieldNames.Num(), 7);
	TestEqual(TEXT("Request fields are the documented seven"), FString::Join(FieldNames, TEXT(",")), FString(TEXT("SchemaVersion,AbilityId,ContentVersion,Phase,Sequence,Aim,ClientServerTimeSeconds")));
	TestEqual(TEXT("Request schema version starts at 2"), static_cast<int32>(FAethelnCombatActivationRequest().SchemaVersion), 2);
	TestTrue(TEXT("Default aim is explicitly zero"), FAethelnCombatActivationRequest().Aim.IsZero());
	TestEqual(TEXT("Phase has only Press and Release (plus the generated maximum)"), StaticEnum<EAethelnActivationPhase>()->NumEnums(), 3);

	const UFunction* SubmitFunction = UAethelnAbilitySystemComponent::StaticClass()->FindFunctionByName(TEXT("ServerSubmitActivation"));
	if (TestNotNull(TEXT("Seam RPC exists"), SubmitFunction))
	{
		TestTrue(TEXT("Seam RPC is a reliable server RPC"), SubmitFunction->HasAllFunctionFlags(FUNC_Net | FUNC_NetServer | FUNC_NetReliable));
		TestFalse(TEXT("Seam RPC is not Blueprint callable"), SubmitFunction->HasAnyFunctionFlags(FUNC_BlueprintCallable));
		int32 ParameterCount = 0;
		for (TFieldIterator<FProperty> ParameterIt(SubmitFunction); ParameterIt && ParameterIt->HasAnyPropertyFlags(CPF_Parm); ++ParameterIt)
		{
			++ParameterCount;
			const FStructProperty* StructParameter = CastField<FStructProperty>(*ParameterIt);
			TestTrue(TEXT("The seam RPC's only parameter is the request"), StructParameter != nullptr && StructParameter->Struct == RequestStruct);
		}
		TestEqual(TEXT("Seam RPC takes exactly one parameter"), ParameterCount, 1);
	}
	const UFunction* OutcomeFunction = UAethelnAbilitySystemComponent::StaticClass()->FindFunctionByName(TEXT("ClientActivationOutcome"));
	if (TestNotNull(TEXT("Outcome RPC exists"), OutcomeFunction))
	{
		TestTrue(TEXT("Outcome RPC is a reliable owning-client RPC"), OutcomeFunction->HasAllFunctionFlags(FUNC_Net | FUNC_NetClient | FUNC_NetReliable));
		TestFalse(TEXT("Outcome RPC is not multicast"), OutcomeFunction->HasAnyFunctionFlags(FUNC_NetMulticast));
	}
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationValidateMatrixTest,
	"Aetheln.GameCombat.ActivationSeam.ValidateMatrix",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationValidateMatrixTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	// Step 1: the rate bucket, with an injected clock. Test-set values, not tuning.
	{
		FAethelnActivationRateBucket Bucket;
		TestTrue(TEXT("A fresh bucket starts full (1)"), Bucket.TryConsume(10.0, 2.0, 1.0));
		TestTrue(TEXT("A fresh bucket starts full (2)"), Bucket.TryConsume(10.0, 2.0, 1.0));
		TestFalse(TEXT("An empty bucket admits nothing"), Bucket.TryConsume(10.0, 2.0, 1.0));
		TestFalse(TEXT("Half a token admits nothing"), Bucket.TryConsume(10.5, 2.0, 1.0));
		TestTrue(TEXT("A whole refilled token admits one message"), Bucket.TryConsume(11.0, 2.0, 1.0));
		TestFalse(TEXT("The refilled token is spent"), Bucket.TryConsume(11.0, 2.0, 1.0));
		TestTrue(TEXT("Refill is capped at capacity (1)"), Bucket.TryConsume(100.0, 2.0, 1.0));
		TestTrue(TEXT("Refill is capped at capacity (2)"), Bucket.TryConsume(100.0, 2.0, 1.0));
		TestFalse(TEXT("Refill is capped at capacity (3)"), Bucket.TryConsume(100.0, 2.0, 1.0));
		TestFalse(TEXT("A clock moving backwards refills nothing"), Bucket.TryConsume(50.0, 2.0, 1.0));
		TestFalse(TEXT("A backwards clock does not rewind the refill point"), Bucket.TryConsume(100.5, 2.0, 1.0));
		TestTrue(TEXT("Refill resumes from the latest time seen"), Bucket.TryConsume(101.0, 2.0, 1.0));

		FAethelnActivationRateBucket NoRefill;
		TestTrue(TEXT("Capacity without refill admits the capacity"), NoRefill.TryConsume(0.0, 1.0, 0.0));
		TestFalse(TEXT("Without refill nothing more is admitted"), NoRefill.TryConsume(1000000.0, 1.0, 0.0));

		for (const TPair<double, double>& Invalid : TArray<TPair<double, double>>{
			{ 0.0, 1.0 },
			{ 0.5, 1.0 },
			{ -5.0, 1.0 },
			{ 2.0, -1.0 },
			{ std::numeric_limits<double>::quiet_NaN(), 1.0 },
			{ std::numeric_limits<double>::infinity(), 1.0 },
			{ 2.0, std::numeric_limits<double>::quiet_NaN() } })
		{
			FAethelnActivationRateBucket InvalidBucket;
			TestFalse(*FString::Printf(TEXT("Capacity %f and refill %f fail closed"), Invalid.Key, Invalid.Value), InvalidBucket.TryConsume(0.0, Invalid.Key, Invalid.Value));
		}
	}

	// Steps 2 to 7: the pure validator.
	FAethelnActivationValidationState ValidState;
	ValidState.bHasPossessedAvatar = true;
	ValidState.LastAcceptedSequence = 5;
	ValidState.bAbilityGranted = true;
	ValidState.GrantedContentVersion = 3;
	ValidState.bAcceptsRelease = true;
	ValidState.NowSeconds = 10.0;
	ValidState.ReferenceAim = FVector::ForwardVector;
	ValidState.LastAcceptedAim = FVector::ForwardVector;
	ValidState.LastAcceptedClientTimeSeconds = 10.0;
	ValidState.Bounds = AethelnCombatTests::MakeTestAimTimeBounds();

	FAethelnCombatActivationRequest ValidRequest;
	ValidRequest.AbilityId = ProbeId();
	ValidRequest.ContentVersion = 3;
	ValidRequest.Phase = EPhase::Press;
	ValidRequest.Sequence = 6;
	ValidRequest.Aim = FVector::ForwardVector;
	ValidRequest.ClientServerTimeSeconds = 10.0;

	auto Check = [this](const TCHAR* What, const FAethelnCombatActivationRequest& Request, const FAethelnActivationValidationState& State, EResult Expected, bool bExpectedResolved)
	{
		bool bResolved = !bExpectedResolved;
		FVector AcceptedAim;
		EAethelnAimCorrection Correction;
		ExpectResult(*this, What, UAethelnAbilitySystemComponent::ValidateRequest(Request, State, bResolved, AcceptedAim, Correction), Expected);
		TestEqual(*FString::Printf(TEXT("%s: ability resolution"), What), bResolved, bExpectedResolved);
	};

	Check(TEXT("A valid Press"), ValidRequest, ValidState, EResult::Accepted, true);

	FAethelnActivationValidationState State = ValidState;
	State.bAvatarBeingDestroyed = true;
	Check(TEXT("A dying avatar"), ValidRequest, State, EResult::ActorDestroyed, false);
	State = ValidState;
	State.bHasPossessedAvatar = false;
	Check(TEXT("No possessed avatar"), ValidRequest, State, EResult::ConnectionClosed, false);

	FAethelnCombatActivationRequest Request = ValidRequest;
	Request.SchemaVersion = AethelnActivation::SchemaVersion + 1;
	Check(TEXT("Another schema version"), Request, ValidState, EResult::IncompatibleVersion, false);

	for (const TPair<uint32, EResult>& Case : TArray<TPair<uint32, EResult>>{
		{ 0u, EResult::StaleSequence },
		{ 4u, EResult::StaleSequence },
		{ 5u, EResult::DuplicateSequence },
		{ 1000u, EResult::Accepted },
		{ MAX_uint32, EResult::Accepted } })
	{
		Request = ValidRequest;
		Request.Sequence = Case.Key;
		Check(*FString::Printf(TEXT("Sequence %u after 5"), Case.Key), Request, ValidState, Case.Value, Case.Value == EResult::Accepted);
	}
	State = ValidState;
	State.LastAcceptedSequence = 0;
	Request = ValidRequest;
	Request.Sequence = 0;
	Check(TEXT("Sequence 0 before any acceptance is stale, not a duplicate"), Request, State, EResult::StaleSequence, false);

	const FGameplayTag AbilityFamily = FGameplayTag::RequestGameplayTag(TEXT("Ability"), false);
	TestTrue(TEXT("The Ability family root is a registered tag"), AbilityFamily.IsValid());
	for (const FGameplayTag& UnknownId : { FGameplayTag(), AbilityFamily, AethelnCombatTestTags::Test_Trigger.GetTag() })
	{
		Request = ValidRequest;
		Request.AbilityId = UnknownId;
		Check(*FString::Printf(TEXT("AbilityId '%s'"), *UnknownId.ToString()), Request, ValidState, EResult::MalformedRequest, false);
	}
	State = ValidState;
	State.bAbilityGranted = false;
	Check(TEXT("A known ability that is not granted"), ValidRequest, State, EResult::ActivationBlocked, false);

	Request = ValidRequest;
	Request.ContentVersion = 2;
	Check(TEXT("Another content version"), Request, ValidState, EResult::IncompatibleVersion, true);

	State = ValidState;
	State.bAbilityActive = true;
	Check(TEXT("Press while active"), ValidRequest, State, EResult::ActivationBlocked, true);
	Request = ValidRequest;
	Request.Phase = EPhase::Release;
	Check(TEXT("A valid Release"), Request, State, EResult::Accepted, true);
	State.bAcceptsRelease = false;
	Check(TEXT("Release on an ability that does not declare it"), Request, State, EResult::MalformedRequest, true);
	State = ValidState;
	Check(TEXT("Release while not active"), Request, State, EResult::ActivationBlocked, true);
	Request.Phase = static_cast<EPhase>(7);
	Check(TEXT("An unknown phase"), Request, ValidState, EResult::MalformedRequest, true);

	// Precedence: every step fails at once, then each is fixed in order.
	FAethelnActivationValidationState BadState;
	BadState.bAvatarBeingDestroyed = true;
	BadState.LastAcceptedSequence = 5;
	BadState.bAbilityActive = true;
	FAethelnCombatActivationRequest BadRequest;
	BadRequest.SchemaVersion = AethelnActivation::SchemaVersion + 1;
	BadRequest.Sequence = 0;
	BadRequest.ContentVersion = 2;
	Check(TEXT("Precedence: step 2, dying"), BadRequest, BadState, EResult::ActorDestroyed, false);
	BadState.bAvatarBeingDestroyed = false;
	Check(TEXT("Precedence: step 2, no avatar"), BadRequest, BadState, EResult::ConnectionClosed, false);
	BadState.bHasPossessedAvatar = true;
	Check(TEXT("Precedence: step 3"), BadRequest, BadState, EResult::IncompatibleVersion, false);
	BadRequest.SchemaVersion = AethelnActivation::SchemaVersion;
	Check(TEXT("Precedence: step 4"), BadRequest, BadState, EResult::StaleSequence, false);
	BadRequest.Sequence = 6;
	Check(TEXT("Precedence: step 5, unknown"), BadRequest, BadState, EResult::MalformedRequest, false);
	BadRequest.AbilityId = ProbeId();
	Check(TEXT("Precedence: step 5, not granted"), BadRequest, BadState, EResult::ActivationBlocked, false);
	BadState.bAbilityGranted = true;
	BadState.GrantedContentVersion = 3;
	Check(TEXT("Precedence: step 6"), BadRequest, BadState, EResult::IncompatibleVersion, true);
	BadRequest.ContentVersion = 3;
	BadState.NowSeconds = ValidState.NowSeconds;
	BadState.ReferenceAim = ValidState.ReferenceAim;
	BadState.LastAcceptedAim = ValidState.LastAcceptedAim;
	BadState.LastAcceptedClientTimeSeconds = ValidState.LastAcceptedClientTimeSeconds;
	BadState.Bounds = ValidState.Bounds;
	BadRequest.Aim = ValidRequest.Aim;
	BadRequest.ClientServerTimeSeconds = ValidRequest.ClientServerTimeSeconds;
	Check(TEXT("Precedence: step 7"), BadRequest, BadState, EResult::ActivationBlocked, true);
	BadState.bAbilityActive = false;
	Check(TEXT("Precedence: all fixed"), BadRequest, BadState, EResult::Accepted, true);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationRejectionHasNoSideEffectTest,
	"Aetheln.GameCombat.ActivationSeam.RejectionHasNoSideEffect",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationRejectionHasNoSideEffectTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	FScopedCombatTestWorld TestWorld;
	FSeamFixture Fixture;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnSeamProbeTestAbility& Probe = *Fixture.Probe;
	UAethelnAbilitySystemComponent& AbilitySystem = *Fixture.Player.AbilitySystem;

	auto ExpectNoSideEffect = [&](const FString& Case)
	{
		TestEqual(Case + TEXT(": no cost"), Probe.CostApplications, 0);
		TestEqual(Case + TEXT(": no cooldown"), Probe.CooldownApplications, 0);
		TestFalse(Case + TEXT(": no state tag"), Fixture.HasProbeStateTag());
		TestFalse(Case + TEXT(": not active"), Fixture.IsActive(Fixture.ProbeHandle));
		TestFalse(Case + TEXT(": no activation id"), Probe.GetActivationId().IsValid());
	};

	// Every rejection uses sequence 1. If any advanced the sequence, the final Press with 1 would be a duplicate.
	Probe.bTestOnCooldown = true;
	ExpectResult(*this, TEXT("On cooldown"), Fixture.Submit(1, ProbeId()), EResult::OnCooldown);
	ExpectNoSideEffect(TEXT("On cooldown"));
	Probe.bTestOnCooldown = false;

	Probe.bTestInsufficientResource = true;
	ExpectResult(*this, TEXT("Insufficient resource"), Fixture.Submit(1, ProbeId()), EResult::InsufficientResource);
	ExpectNoSideEffect(TEXT("Insufficient resource"));
	Probe.bTestInsufficientResource = false;

	AbilitySystem.AddLooseGameplayTag(AethelnCombatTestTags::Test_Blocking);
	ExpectResult(*this, TEXT("Blocked by a tag"), Fixture.Submit(1, ProbeId()), EResult::ActivationBlocked);
	ExpectNoSideEffect(TEXT("Blocked by a tag"));
	AbilitySystem.RemoveLooseGameplayTag(AethelnCombatTestTags::Test_Blocking);

	ExpectResult(*this, TEXT("Content version mismatch"), Fixture.Submit(1, ProbeId(), EPhase::Press, 2), EResult::IncompatibleVersion);
	ExpectNoSideEffect(TEXT("Content version mismatch"));
	ExpectResult(*this, TEXT("Schema version mismatch"), Fixture.Submit(1, ProbeId(), EPhase::Press, 1, AethelnActivation::SchemaVersion + 1), EResult::IncompatibleVersion);
	ExpectNoSideEffect(TEXT("Schema version mismatch"));
	ExpectResult(*this, TEXT("Unknown ability"), Fixture.Submit(1, FGameplayTag()), EResult::MalformedRequest);
	ExpectNoSideEffect(TEXT("Unknown ability"));
	ExpectResult(*this, TEXT("Zero sequence"), Fixture.Submit(0, ProbeId()), EResult::StaleSequence);
	ExpectNoSideEffect(TEXT("Zero sequence"));
	ExpectResult(*this, TEXT("Release undeclared"), Fixture.Submit(1, LongRunningId(), EPhase::Release), EResult::MalformedRequest);
	ExpectNoSideEffect(TEXT("Release undeclared"));
	ExpectResult(*this, TEXT("Release while not active"), Fixture.Submit(1, ProbeId(), EPhase::Release), EResult::ActivationBlocked);
	ExpectNoSideEffect(TEXT("Release while not active"));

	// A failing commit activates, applies nothing, and ends.
	Probe.bTestFailCommit = true;
	ExpectResult(*this, TEXT("Failing commit"), Fixture.Submit(1, ProbeId()), EResult::InternalFailure);
	ExpectNoSideEffect(TEXT("Failing commit"));

	// A failed commit that does not end itself is cancelled by the seam.
	Probe.bTestKeepActiveOnFailedCommit = true;
	ExpectResult(*this, TEXT("Failing commit that keeps running"), Fixture.Submit(1, ProbeId()), EResult::InternalFailure);
	ExpectNoSideEffect(TEXT("Failing commit that keeps running"));
	Probe.bTestKeepActiveOnFailedCommit = false;
	Probe.bTestFailCommit = false;

	// The partial commits are refused and apply nothing; the uncommitted activation is cancelled.
	Probe.bTestUsePartialCommit = true;
	ExpectResult(*this, TEXT("Partial commit"), Fixture.Submit(1, ProbeId()), EResult::InternalFailure);
	TestFalse(TEXT("CommitAbilityCost and CommitAbilityCooldown are refused"), Probe.bTestPartialCommitSucceeded);
	ExpectNoSideEffect(TEXT("Partial commit"));
	Probe.bTestUsePartialCommit = false;

	ExpectResult(*this, TEXT("Sequence 1 was never advanced"), Fixture.Submit(1, ProbeId()), EResult::Accepted);
	TestEqual(TEXT("Acceptance applies one cost"), Probe.CostApplications, 1);
	TestEqual(TEXT("Acceptance applies one cooldown"), Probe.CooldownApplications, 1);
	TestTrue(TEXT("Acceptance adds the state tag"), Fixture.HasProbeStateTag());
	TestTrue(TEXT("Acceptance creates an activation id"), Probe.GetActivationId().IsValid());
	const FGuid AcceptedActivationId = Probe.GetActivationId();

	ExpectResult(*this, TEXT("Replayed Press"), Fixture.Submit(1, ProbeId()), EResult::DuplicateSequence);
	ExpectResult(*this, TEXT("Press while active"), Fixture.Submit(2, ProbeId()), EResult::ActivationBlocked);
	TestEqual(TEXT("Rejections while active add no cost"), Probe.CostApplications, 1);
	TestEqual(TEXT("Rejections while active keep the activation id"), Probe.GetActivationId(), AcceptedActivationId);

	ExpectResult(*this, TEXT("Valid Release"), Fixture.Submit(2, ProbeId(), EPhase::Release), EResult::Accepted);
	TestFalse(TEXT("Release ends the activation"), Fixture.IsActive(Fixture.ProbeHandle));
	TestFalse(TEXT("Release removes the state tag"), Fixture.HasProbeStateTag());
	TestEqual(TEXT("Release applies no cost"), Probe.CostApplications, 1);
	ExpectResult(*this, TEXT("Replayed Release"), Fixture.Submit(2, ProbeId(), EPhase::Release), EResult::DuplicateSequence);

	ExpectOutcomes(*this, TEXT("One owner outcome per request"), Fixture.Outcomes, {
		{ 1u, EResult::OnCooldown },
		{ 1u, EResult::InsufficientResource },
		{ 1u, EResult::ActivationBlocked },
		{ 1u, EResult::IncompatibleVersion },
		{ 1u, EResult::IncompatibleVersion },
		{ 1u, EResult::MalformedRequest },
		{ 0u, EResult::StaleSequence },
		{ 1u, EResult::MalformedRequest },
		{ 1u, EResult::ActivationBlocked },
		{ 1u, EResult::InternalFailure },
		{ 1u, EResult::InternalFailure },
		{ 1u, EResult::InternalFailure },
		{ 1u, EResult::Accepted },
		{ 1u, EResult::DuplicateSequence },
		{ 2u, EResult::ActivationBlocked },
		{ 2u, EResult::Accepted },
		{ 2u, EResult::DuplicateSequence } });
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationStockRoutesRefusedTest,
	"Aetheln.GameCombat.ActivationSeam.StockRoutesRefused",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationStockRoutesRefusedTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	FScopedCombatTestWorld TestWorld;
	FSeamFixture Fixture;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnSeamProbeTestAbility& Probe = *Fixture.Probe;
	UAethelnAbilitySystemComponent& AbilitySystem = *Fixture.Player.AbilitySystem;

	auto ExpectNothingActivated = [&](const FString& Route)
	{
		TestFalse(Route + TEXT(": the probe is not active"), Fixture.IsActive(Fixture.ProbeHandle));
		TestFalse(Route + TEXT(": the long-running ability is not active"), Fixture.IsActive(Fixture.LongRunningHandle));
		TestEqual(Route + TEXT(": nothing committed a cost"), Probe.CostApplications, 0);
		TestEqual(Route + TEXT(": nothing committed a cooldown"), Probe.CooldownApplications, 0);
		TestFalse(Route + TEXT(": no state tag"), Fixture.HasProbeStateTag());
	};

	AbilitySystem.CallServerTryActivateAbilityForTests(Fixture.ProbeHandle);
	ExpectNothingActivated(TEXT("ServerTryActivateAbility"));
	AbilitySystem.CallServerTryActivateAbilityWithEventDataForTests(Fixture.ProbeHandle, FGameplayEventData());
	ExpectNothingActivated(TEXT("ServerTryActivateAbilityWithEventData"));

	FServerAbilityRPCBatch Batch;
	Batch.AbilitySpecHandle = Fixture.ProbeHandle;
	Batch.InputPressed = true;
	Batch.Started = true;
	AbilitySystem.ServerAbilityRPCBatch(Batch);
	ExpectNothingActivated(TEXT("ServerAbilityRPCBatch"));
	TestFalse(TEXT("The dropped batch wrote no target data"), AbilitySystem.HasReplicatedTargetDataForTests(Fixture.ProbeHandle, Batch.PredictionKey));
	// Control: a local, non-RPC cache writer proves the accessor sees an entry.
	AbilitySystem.InvokeReplicatedEvent(EAbilityGenericReplicatedEvent::GenericConfirm, Fixture.ProbeHandle, Batch.PredictionKey, Batch.PredictionKey);
	TestTrue(TEXT("Control: the cache accessor sees a local replicated-event write"), AbilitySystem.HasReplicatedTargetDataForTests(Fixture.ProbeHandle, Batch.PredictionKey));

	TestFalse(TEXT("TryActivateAbility refuses on the server"), AbilitySystem.TryActivateAbility(Fixture.ProbeHandle));
	ExpectNothingActivated(TEXT("TryActivateAbility"));
	TestFalse(TEXT("TryActivateAbilityByClass refuses"), AbilitySystem.TryActivateAbilityByClass(UAethelnSeamProbeTestAbility::StaticClass()));
	ExpectNothingActivated(TEXT("TryActivateAbilityByClass"));
	TestFalse(TEXT("TryActivateAbilitiesByTag refuses"), AbilitySystem.TryActivateAbilitiesByTag(FGameplayTagContainer(ProbeId())));
	ExpectNothingActivated(TEXT("TryActivateAbilitiesByTag"));

	FGameplayAbilitySpec OnceSpec(UAethelnLongRunningTestAbility::StaticClass(), 1);
	const FGameplayAbilitySpecHandle OnceHandle = AbilitySystem.GiveAbilityAndActivateOnce(OnceSpec);
	TestFalse(TEXT("GiveAbilityAndActivateOnce activates nothing"), Fixture.IsActive(OnceHandle));
	ExpectNothingActivated(TEXT("GiveAbilityAndActivateOnce"));

	// Grant validation refuses triggers, so the trigger case grants its test ability directly.
	const FGameplayAbilitySpecHandle TriggeredHandle = AbilitySystem.GiveAbility(FGameplayAbilitySpec(UAethelnTriggeredTestAbility::StaticClass(), 1));
	FGameplayEventData Payload;
	Payload.EventTag = AethelnCombatTestTags::Test_Trigger;
	AbilitySystem.HandleGameplayEvent(AethelnCombatTestTags::Test_Trigger, &Payload);
	const FGameplayAbilitySpec* TriggeredSpec = AbilitySystem.FindAbilitySpecFromHandle(TriggeredHandle);
	const UAethelnTriggeredTestAbility* Triggered = TriggeredSpec != nullptr ? Cast<UAethelnTriggeredTestAbility>(TriggeredSpec->GetPrimaryInstance()) : nullptr;
	if (TestNotNull(TEXT("Triggered test ability is granted"), Triggered))
	{
		TestEqual(TEXT("A matching gameplay event activates nothing"), Triggered->Activations, 0);
	}
	TestFalse(TEXT("The triggered ability is not active"), Fixture.IsActive(TriggeredHandle));
	ExpectNothingActivated(TEXT("Gameplay event trigger"));

	// The scope passes only the handle the seam is activating.
	Probe.TestNestedActivationClass = UAethelnLongRunningTestAbility::StaticClass();
	ExpectResult(*this, TEXT("Control: the seam activates the probe"), Fixture.Submit(1, ProbeId()), EResult::Accepted);
	TestFalse(TEXT("An ability activated from inside another's ActivateAbility is refused"), Probe.bTestNestedActivationSucceeded);
	TestFalse(TEXT("The nested ability is not active"), Fixture.IsActive(Fixture.LongRunningHandle));
	ExpectResult(*this, TEXT("Control: the seam activates the long-running ability"), Fixture.Submit(2, LongRunningId()), EResult::Accepted);
	TestTrue(TEXT("Control: the long-running ability is active"), Fixture.IsActive(Fixture.LongRunningHandle));
	ExpectOutcomes(*this, TEXT("Refused stock routes send no outcome"), Fixture.Outcomes, { { 1u, EResult::Accepted }, { 2u, EResult::Accepted } });
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationRateBoundTest,
	"Aetheln.GameCombat.ActivationSeam.RateBound",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationRateBoundTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	FScopedCombatTestWorld TestWorld;
	if (!TestNotNull(TEXT("Test world exists"), TestWorld.World))
	{
		return false;
	}

	// The placeholders load from DefaultGame.ini into the class default and into a PlayerState's ASC.
	const TCHAR* Section = TEXT("/Script/GameCombat.AethelnAbilitySystemComponent");
	float IniCapacity = 0.0f;
	float IniRefill = 0.0f;
	TestTrue(TEXT("DefaultGame.ini sets the bucket capacity"), GConfig->GetFloat(Section, TEXT("ProvisionalActivationBucketCapacity"), IniCapacity, GGameIni));
	TestTrue(TEXT("DefaultGame.ini sets the bucket refill"), GConfig->GetFloat(Section, TEXT("ProvisionalActivationBucketRefillPerSecond"), IniRefill, GGameIni));
	TestTrue(TEXT("The configured capacity admits at least one request"), IniCapacity >= 1.0f);
	TestTrue(TEXT("The configured refill is positive"), IniRefill > 0.0f);
	TestEqual(TEXT("The class default loaded the capacity"), GetDefault<UAethelnAbilitySystemComponent>()->ProvisionalActivationBucketCapacity, IniCapacity);
	TestEqual(TEXT("The class default loaded the refill"), GetDefault<UAethelnAbilitySystemComponent>()->ProvisionalActivationBucketRefillPerSecond, IniRefill);
	if (const AAethelnPlayerState* ConfiguredPlayerState = TestWorld.Spawn<AAethelnPlayerState>())
	{
		TestEqual(TEXT("A PlayerState's ASC carries the configured capacity"), ConfiguredPlayerState->GetAethelnAbilitySystemComponent()->ProvisionalActivationBucketCapacity, IniCapacity);
		TestEqual(TEXT("A PlayerState's ASC carries the configured refill"), ConfiguredPlayerState->GetAethelnAbilitySystemComponent()->ProvisionalActivationBucketRefillPerSecond, IniRefill);
	}

	FSeamFixture Fixture;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnSeamProbeTestAbility& Probe = *Fixture.Probe;
	UAethelnAbilitySystemComponent& AbilitySystem = *Fixture.Player.AbilitySystem;

	// Test-set bucket, not tuning: three tokens, one per second. The clock is the world's real time.
	AbilitySystem.ProvisionalActivationBucketCapacity = 3.0f;
	AbilitySystem.ProvisionalActivationBucketRefillPerSecond = 1.0f;
	TestWorld.World->RealTimeSeconds = 100.0;

	ExpectResult(*this, TEXT("In bound (1)"), Fixture.Submit(1, ProbeId()), EResult::Accepted);
	ExpectResult(*this, TEXT("In bound (2)"), Fixture.Submit(2, ProbeId(), EPhase::Release), EResult::Accepted);
	ExpectResult(*this, TEXT("In bound (3)"), Fixture.Submit(3, ProbeId()), EResult::Accepted);
	TestEqual(TEXT("In-bound requests committed normally"), Probe.CostApplications, 2);

	ExpectResult(*this, TEXT("Excess request"), Fixture.Submit(4, ProbeId(), EPhase::Release), EResult::RateLimited);
	TestTrue(TEXT("The rate-limited Release changed nothing"), Fixture.IsActive(Fixture.ProbeHandle));
	TestEqual(TEXT("The rate-limited request committed nothing"), Probe.CostApplications, 2);
	AbilitySystem.CallServerTryActivateAbilityForTests(Fixture.ProbeHandle);

	TestWorld.World->RealTimeSeconds = 101.0;
	AbilitySystem.CallServerTryActivateAbilityForTests(Fixture.ProbeHandle);
	ExpectResult(*this, TEXT("A refused stock-route call took the refilled token"), Fixture.Submit(4, ProbeId(), EPhase::Release), EResult::RateLimited);
	TestTrue(TEXT("The probe is still active"), Fixture.IsActive(Fixture.ProbeHandle));

	TestWorld.World->RealTimeSeconds = 102.0;
	ExpectResult(*this, TEXT("Rate-limited attempts advanced no sequence"), Fixture.Submit(4, ProbeId(), EPhase::Release), EResult::Accepted);
	TestFalse(TEXT("The admitted Release ended the probe"), Fixture.IsActive(Fixture.ProbeHandle));
	TestEqual(TEXT("Nothing committed beyond the in-bound requests"), Probe.CostApplications, 2);

	ExpectOutcomes(*this, TEXT("One RateLimited outcome per limited window"), Fixture.Outcomes, {
		{ 1u, EResult::Accepted },
		{ 2u, EResult::Accepted },
		{ 3u, EResult::Accepted },
		{ 4u, EResult::RateLimited },
		{ 4u, EResult::RateLimited },
		{ 4u, EResult::Accepted } });

	// Step 1 runs before steps 2 to 7, so rejected requests spend tokens too. Test-set bucket: three tokens, no refill.
	FSeamFixture DrainFixture;
	if (!DrainFixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnAbilitySystemComponent& DrainAbilitySystem = *DrainFixture.Player.AbilitySystem;
	DrainAbilitySystem.ProvisionalActivationBucketCapacity = 3.0f;
	DrainAbilitySystem.ProvisionalActivationBucketRefillPerSecond = 0.0f;
	ExpectResult(*this, TEXT("A zero-sequence request spends a token"), DrainFixture.Submit(0, ProbeId()), EResult::StaleSequence);
	ExpectResult(*this, TEXT("A malformed request spends a token"), DrainFixture.Submit(1, FGameplayTag()), EResult::MalformedRequest);
	DrainFixture.Player.Controller->UnPossess();
	ExpectResult(*this, TEXT("A no-avatar request spends a token"), DrainFixture.Submit(1, ProbeId()), EResult::ConnectionClosed);
	DrainFixture.Player.Controller->Possess(DrainFixture.Pawn);
	ExpectResult(*this, TEXT("The next malformed request is rate limited before validation"), DrainFixture.Submit(1, FGameplayTag()), EResult::RateLimited);
	ExpectResult(*this, TEXT("A valid request is rate limited too"), DrainFixture.Submit(1, ProbeId()), EResult::RateLimited);
	TestFalse(TEXT("Nothing activated on the drained bucket"), DrainFixture.IsActive(DrainFixture.ProbeHandle));
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationGrantValidationTest,
	"Aetheln.GameCombat.ActivationSeam.GrantValidationFailsClosed",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationGrantValidationTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	constexpr int32 ExpectedRefusals = 20;
	AddExpectedMessagePlain(TEXT("Refused to grant ability"), ELogVerbosity::Warning, EAutomationExpectedMessageFlags::Contains, ExpectedRefusals);

	TestTrue(TEXT("The probe definition is grantable"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnSeamProbeTestAbility::StaticClass(), 1)));
	TestTrue(TEXT("The long-running definition is grantable"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnLongRunningTestAbility::StaticClass(), 1)));
	TestFalse(TEXT("A plain UGameplayAbility is refused"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UGameplayAbility::StaticClass(), 1)));
	TestFalse(TEXT("A null ability is refused"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(TSubclassOf<UGameplayAbility>(), 1)));
	TestFalse(TEXT("A spec input id is refused"), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(UAethelnSeamProbeTestAbility::StaticClass(), 1, 3)));
	FGameplayAbilitySpec DynamicTriggerSpec(UAethelnSeamProbeTestAbility::StaticClass(), 1);
	DynamicTriggerSpec.DynamicAbilityTriggers.AddDefaulted_GetRef().TriggerTag = AethelnCombatTestTags::Test_Trigger;
	TestFalse(TEXT("Spec-level dynamic ability triggers are refused"), AAethelnPlayerState::IsGrantableAbilitySpec(DynamicTriggerSpec));

	// Each case changes one field of an otherwise grantable transient definition.
	auto ExpectRefused = [this](const TCHAR* Case, TFunctionRef<void(UAethelnSeamProbeTestAbility&)> Change)
	{
		UAethelnSeamProbeTestAbility* Definition = NewObject<UAethelnSeamProbeTestAbility>(GetTransientPackage());
		TestTrue(*FString::Printf(TEXT("%s: the unchanged definition is grantable"), Case), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition, 1)));
		Change(*Definition);
		TestFalse(*FString::Printf(TEXT("%s is refused"), Case), AAethelnPlayerState::IsGrantableAbilitySpec(FGameplayAbilitySpec(Definition, 1)));
	};
	using EInstancing = EGameplayAbilityInstancingPolicy::Type;
	using EExecution = EGameplayAbilityNetExecutionPolicy::Type;
	using ESecurity = EGameplayAbilityNetSecurityPolicy::Type;
	ExpectRefused(TEXT("A client security policy"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestPolicies(EInstancing::InstancedPerActor, EExecution::ServerOnly, ESecurity::ClientOrServer); });
	ExpectRefused(TEXT("A predicted execution policy"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestPolicies(EInstancing::InstancedPerActor, EExecution::LocalPredicted, ESecurity::ServerOnly); });
	ExpectRefused(TEXT("Per-execution instancing"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestPolicies(EInstancing::InstancedPerExecution, EExecution::ServerOnly, ESecurity::ServerOnly); });
	ExpectRefused(TEXT("A missing identity tag"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestAbilityId(FGameplayTag()); });
	ExpectRefused(TEXT("An identity outside the Ability family"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestAbilityId(AethelnCombatTestTags::Test_Trigger); });
	ExpectRefused(TEXT("The bare Ability family root"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.SetTestAbilityId(FGameplayTag::RequestGameplayTag(TEXT("Ability"), false)); });
	ExpectRefused(TEXT("Content version 0"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ContentVersion = 0; });
	ExpectRefused(TEXT("A negative cost"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ProvisionalEnduranceCost = -1.0f; });
	ExpectRefused(TEXT("A NaN cost"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ProvisionalEnduranceCost = std::numeric_limits<float>::quiet_NaN(); });
	ExpectRefused(TEXT("An infinite cost"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ProvisionalEnduranceCost = std::numeric_limits<float>::infinity(); });
	ExpectRefused(TEXT("A negative cooldown"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ProvisionalCooldownSeconds = -1.0f; });
	ExpectRefused(TEXT("A NaN cooldown"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.ProvisionalCooldownSeconds = std::numeric_limits<float>::quiet_NaN(); });
	ExpectRefused(TEXT("Ability triggers"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.AddTestTrigger(AethelnCombatTestTags::Test_Trigger); });
	ExpectRefused(TEXT("Direct input replication"), [](UAethelnSeamProbeTestAbility& Ability) { Ability.bReplicateInputDirectly = true; });

	// End to end: the PlayerState grants only what passes validation.
	FScopedCombatTestWorld TestWorld;
	FTestPlayer Player;
	if (!SpawnTestPlayer(*this, TestWorld, Player, {
		UGameplayAbility::StaticClass(),
		UAethelnTriggeredTestAbility::StaticClass(),
		UAethelnSeamProbeTestAbility::StaticClass() }))
	{
		return false;
	}
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("GameCore player pawn exists"), Pawn))
	{
		return false;
	}
	Player.Controller->Possess(Pawn);
	const TArray<FGameplayAbilitySpec>& Granted = Player.AbilitySystem->GetActivatableAbilities();
	TestEqual(TEXT("Only the valid configured ability is granted"), Granted.Num(), 1);
	TestTrue(TEXT("The granted ability is the probe"), Granted.Num() == 1 && Granted[0].Ability != nullptr && Granted[0].Ability->IsA<UAethelnSeamProbeTestAbility>());
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationCheatFlagsOffTest,
	"Aetheln.GameCombat.ActivationSeam.CheatFlagsOff",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationCheatFlagsOffTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

	IConsoleVariable* IgnoreCooldowns = IConsoleManager::Get().FindConsoleVariable(TEXT("AbilitySystem.IgnoreCooldowns"));
	IConsoleVariable* IgnoreCosts = IConsoleManager::Get().FindConsoleVariable(TEXT("AbilitySystem.IgnoreCosts"));
	if (!TestNotNull(TEXT("AbilitySystem.IgnoreCooldowns exists"), IgnoreCooldowns)
		|| !TestNotNull(TEXT("AbilitySystem.IgnoreCosts exists"), IgnoreCosts))
	{
		return false;
	}
	TestFalse(TEXT("AbilitySystem.IgnoreCooldowns is off by default"), IgnoreCooldowns->GetBool());
	TestFalse(TEXT("AbilitySystem.IgnoreCosts is off by default"), IgnoreCosts->GetBool());

	struct FRestoreCheats
	{
		IConsoleVariable* Cooldowns;
		IConsoleVariable* Costs;
		~FRestoreCheats()
		{
			Cooldowns->Set(false, ECVF_SetByCode);
			Costs->Set(false, ECVF_SetByCode);
		}
	} RestoreCheats{ IgnoreCooldowns, IgnoreCosts };

	FScopedCombatTestWorld TestWorld;
	FSeamFixture Fixture;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnSeamProbeTestAbility& Probe = *Fixture.Probe;

	IgnoreCooldowns->Set(true, ECVF_SetByCode);
	TestTrue(TEXT("The engine now ignores cooldowns"), UAbilitySystemGlobals::Get().ShouldIgnoreCooldowns());
	Probe.bTestOnCooldown = true;
	ExpectResult(*this, TEXT("The seam ignores IgnoreCooldowns"), Fixture.Submit(1, ProbeId()), EResult::OnCooldown);
	Probe.bTestOnCooldown = false;
	IgnoreCooldowns->Set(false, ECVF_SetByCode);

	IgnoreCosts->Set(true, ECVF_SetByCode);
	TestTrue(TEXT("The engine now ignores costs"), UAbilitySystemGlobals::Get().ShouldIgnoreCosts());
	Probe.bTestInsufficientResource = true;
	ExpectResult(*this, TEXT("The seam ignores IgnoreCosts"), Fixture.Submit(1, ProbeId()), EResult::InsufficientResource);
	Probe.bTestInsufficientResource = false;
	IgnoreCosts->Set(false, ECVF_SetByCode);

	TestFalse(TEXT("Nothing activated under the cheats"), Fixture.IsActive(Fixture.ProbeHandle));
	TestEqual(TEXT("Nothing committed under the cheats"), Probe.CostApplications + Probe.CooldownApplications, 0);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationLifecycleRejectionsTest,
	"Aetheln.GameCombat.ActivationSeam.LifecycleRejections",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationLifecycleRejectionsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;

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
	UAethelnAbilitySystemComponent& AbilitySystem = *Player.AbilitySystem;
	auto Submit = [&AbilitySystem](uint32 Sequence)
	{
		FAethelnCombatActivationRequest Request;
		Request.AbilityId = LongRunningId();
		Request.ContentVersion = 1;
		Request.Sequence = Sequence;
		AethelnCombatTests::FillTestAimAndTime(Request, AbilitySystem);
		return AbilitySystem.ProcessServerRequest(Request);
	};

	ExpectResult(*this, TEXT("No avatar before the first possession"), Submit(1), EResult::ConnectionClosed);

	Player.Controller->Possess(Pawn);
	ExpectResult(*this, TEXT("The sequence did not advance before possession"), Submit(1), EResult::Accepted);

	Player.Controller->UnPossess();
	ExpectResult(*this, TEXT("No avatar after unpossession"), Submit(2), EResult::ConnectionClosed);

	Player.Controller->Possess(Pawn);
	ExpectResult(*this, TEXT("Sequence state survives re-possession (duplicate)"), Submit(1), EResult::DuplicateSequence);
	ExpectResult(*this, TEXT("Sequence state survives re-possession (stale)"), Submit(0), EResult::StaleSequence);
	ExpectResult(*this, TEXT("Unpossession cancelled the activation; the next sequence is accepted"), Submit(2), EResult::Accepted);

	// A request during destruction: the actor is being destroyed but is still the possessed avatar.
	TOptional<EAethelnActivationResult> DuringDestruction;
	const FDelegateHandle DestroyedHandle = TestWorld.World->AddOnActorDestroyedHandler(FOnActorDestroyed::FDelegate::CreateLambda(
		[&](AActor* DestroyedActor)
		{
			if (DestroyedActor == Pawn)
			{
				DuringDestruction = Submit(3);
			}
		}));
	Pawn->Destroy();
	TestWorld.World->RemoveOnActorDestroyedHandler(DestroyedHandle);
	if (TestTrue(TEXT("The request during destruction ran"), DuringDestruction.IsSet()))
	{
		ExpectResult(*this, TEXT("A dying avatar"), DuringDestruction.GetValue(), EResult::ActorDestroyed);
	}
	ExpectResult(*this, TEXT("No avatar after the pawn is destroyed"), Submit(3), EResult::ConnectionClosed);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnActivationTelemetryTest,
	"Aetheln.GameCombat.Telemetry.ActivationOutcomes",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnActivationTelemetryTest::RunTest(const FString& Parameters)
{
	using namespace AethelnActivationSeamTests;
	using ECategory = EAethelnObservabilityCategory;
	using EReason = EAethelnSafeReason;
	using EMetric = EAethelnMetricKind;
	using FSink = FAethelnInMemoryObservabilitySink;
	using FRestrictedSink = FAethelnBoundedRestrictedAuditSink;

	FScopedCombatTestWorld TestWorld(true);
	UAethelnObservabilitySubsystem* Subsystem = TestWorld.GameInstance != nullptr
		? TestWorld.GameInstance->GetSubsystem<UAethelnObservabilitySubsystem>()
		: nullptr;
	if (!TestNotNull(TEXT("Game instance owns the observability service"), Subsystem))
	{
		return false;
	}
	// Without a runtime context the contract drops every event.
	TestTrue(TEXT("Runtime context is set"), Subsystem->SetRuntimeContext(
		EAethelnFlowKind::PrototypeAuthority,
		TEXT("run-activation-seam-test"),
		TEXT("instance-activation-seam-test"),
		TEXT("connection-activation-seam-test")));
	TSharedPtr<FSink, ESPMode::ThreadSafe> Sink = MakeShared<FSink, ESPMode::ThreadSafe>(64);
	TSharedPtr<FRestrictedSink, ESPMode::ThreadSafe> RestrictedSink = MakeShared<FRestrictedSink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Public test sink is accepted"), Subsystem->SetTestSink(Sink));
	TestTrue(TEXT("Restricted test sink is accepted"), Subsystem->SetTestRestrictedSink(RestrictedSink));

	// Ordinary outcomes.
	FSeamFixture Fixture;
	if (!Fixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnSeamProbeTestAbility& Probe = *Fixture.Probe;
	const FString ProbeIdString = ProbeId().ToString();

	ExpectResult(*this, TEXT("Accepted Press"), Fixture.Submit(1, ProbeId()), EResult::Accepted);
	const FString FirstActivationId = ActivationIdString(Probe.GetActivationId());
	ExpectResult(*this, TEXT("Accepted Release"), Fixture.Submit(2, ProbeId(), EPhase::Release), EResult::Accepted);
	Probe.bTestOnCooldown = true;
	ExpectResult(*this, TEXT("On cooldown"), Fixture.Submit(3, ProbeId()), EResult::OnCooldown);
	Probe.bTestOnCooldown = false;
	Probe.bTestInsufficientResource = true;
	ExpectResult(*this, TEXT("Insufficient resource"), Fixture.Submit(3, ProbeId()), EResult::InsufficientResource);
	Probe.bTestInsufficientResource = false;
	Probe.bTestFailCommit = true;
	ExpectResult(*this, TEXT("Failing commit"), Fixture.Submit(3, ProbeId()), EResult::InternalFailure);
	Probe.bTestFailCommit = false;
	ExpectResult(*this, TEXT("Step 6 rejection"), Fixture.Submit(3, ProbeId(), EPhase::Press, 9), EResult::IncompatibleVersion);
	ExpectResult(*this, TEXT("Step 4 rejection"), Fixture.Submit(2, ProbeId()), EResult::DuplicateSequence);
	ExpectResult(*this, TEXT("Step 5 rejection"), Fixture.Submit(3, FGameplayTag()), EResult::MalformedRequest);
	ExpectResult(*this, TEXT("Zero-sequence rejection"), Fixture.Submit(0, ProbeId()), EResult::StaleSequence);
	Fixture.Player.AbilitySystem->CallServerTryActivateAbilityForTests(Fixture.ProbeHandle);

	TestTrue(TEXT("Ordinary outcome dispatch drains"), Subsystem->WaitForIdleForTests());
	const TArray<FAethelnObservabilityEvent>& Events = Sink->GetEvents();
	const TArray<FAethelnMetricSample>& Metrics = Sink->GetMetrics();
	TestEqual(TEXT("One event per ordinary outcome, none for zero sequence or stock routes"), Events.Num(), 8);
	ExpectEvent(*this, Events, 0, ECategory::Ability, ECategory::Ability, EReason::Accepted, 1, FirstActivationId, ProbeIdString);
	ExpectEvent(*this, Events, 1, ECategory::Ability, ECategory::Ability, EReason::Accepted, 2, FirstActivationId, ProbeIdString);
	ExpectEvent(*this, Events, 2, ECategory::Rejection, ECategory::Cooldown, EReason::ActivationBlocked, 3, FString(), ProbeIdString);
	ExpectEvent(*this, Events, 3, ECategory::Rejection, ECategory::Resource, EReason::ActivationBlocked, 3, FString(), ProbeIdString);
	ExpectEvent(*this, Events, 4, ECategory::Rejection, ECategory::Ability, EReason::InternalFailure, 3, FString(), ProbeIdString);
	ExpectEvent(*this, Events, 5, ECategory::Rejection, ECategory::Ability, EReason::IncompatibleVersion, 3, FString(), ProbeIdString);
	ExpectEvent(*this, Events, 6, ECategory::Rejection, ECategory::Ability, EReason::DuplicateSequence, 2, FString(), FString());
	ExpectEvent(*this, Events, 7, ECategory::Rejection, ECategory::Ability, EReason::MalformedRequest, 3, FString(), FString());
	TestEqual(TEXT("One metric per outcome and per refused stock-route call"), Metrics.Num(), 10);
	ExpectMetric(*this, Metrics, 0, EMetric::EventCount, ECategory::Ability, EReason::Accepted, 1);
	ExpectMetric(*this, Metrics, 1, EMetric::EventCount, ECategory::Ability, EReason::Accepted, 1);
	ExpectMetric(*this, Metrics, 2, EMetric::RejectionCount, ECategory::Cooldown, EReason::ActivationBlocked, 1);
	ExpectMetric(*this, Metrics, 3, EMetric::RejectionCount, ECategory::Resource, EReason::ActivationBlocked, 1);
	ExpectMetric(*this, Metrics, 4, EMetric::RejectionCount, ECategory::Ability, EReason::InternalFailure, 1);
	ExpectMetric(*this, Metrics, 5, EMetric::RejectionCount, ECategory::Ability, EReason::IncompatibleVersion, 1);
	ExpectMetric(*this, Metrics, 6, EMetric::RejectionCount, ECategory::Ability, EReason::DuplicateSequence, 1);
	ExpectMetric(*this, Metrics, 7, EMetric::RejectionCount, ECategory::Ability, EReason::MalformedRequest, 1);
	ExpectMetric(*this, Metrics, 8, EMetric::RejectionCount, ECategory::Ability, EReason::StaleSequence, 1);
	ExpectMetric(*this, Metrics, 9, EMetric::RejectionCount, ECategory::Ability, EReason::Rejected, 1);
	const TArray<FAethelnObservabilityEvent>& RestrictedEvents = RestrictedSink->GetEvents();
	if (TestEqual(TEXT("The restricted channel receives the same events"), RestrictedEvents.Num(), Events.Num()))
	{
		for (int32 Index = 0; Index < RestrictedEvents.Num(); ++Index)
		{
			const EAethelnDiagnosticCode Expected = Index < 2 ? EAethelnDiagnosticCode::None : EAethelnDiagnosticCode::ValidationFailed;
			TestTrue(*FString::Printf(TEXT("Restricted event %d keeps its diagnostic code"), Index), RestrictedEvents[Index].DiagnosticCode == Expected);
		}
	}
	ExpectOutcomes(*this, TEXT("One owner outcome per seam request, none per stock route"), Fixture.Outcomes, {
		{ 1u, EResult::Accepted },
		{ 2u, EResult::Accepted },
		{ 3u, EResult::OnCooldown },
		{ 3u, EResult::InsufficientResource },
		{ 3u, EResult::InternalFailure },
		{ 3u, EResult::IncompatibleVersion },
		{ 2u, EResult::DuplicateSequence },
		{ 3u, EResult::MalformedRequest },
		{ 0u, EResult::StaleSequence } });

	// A rate-limited flood, on a second player with its own bucket: one token, no refill.
	FSeamFixture FloodFixture;
	if (!FloodFixture.Init(*this, TestWorld))
	{
		return false;
	}
	UAethelnAbilitySystemComponent& FloodAbilitySystem = *FloodFixture.Player.AbilitySystem;
	FloodAbilitySystem.ProvisionalActivationBucketCapacity = 1.0f;
	FloodAbilitySystem.ProvisionalActivationBucketRefillPerSecond = 0.0f;
	ExpectResult(*this, TEXT("The only token is spent"), FloodFixture.Submit(1, ProbeId()), EResult::Accepted);
	const FString FloodActivationId = ActivationIdString(FloodFixture.Probe->GetActivationId());
	TestTrue(TEXT("Flood setup drains"), Subsystem->WaitForIdleForTests());
	TSharedPtr<FSink, ESPMode::ThreadSafe> FloodSink = MakeShared<FSink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Flood sink is accepted"), Subsystem->SetTestSink(FloodSink));
	FloodFixture.Outcomes.Reset();

	for (uint32 Sequence = 2; Sequence <= 6; ++Sequence)
	{
		ExpectResult(*this, FString::Printf(TEXT("Flood request %u"), Sequence), FloodFixture.Submit(Sequence, ProbeId(), EPhase::Release), EResult::RateLimited);
	}
	for (int32 Call = 0; Call < 3; ++Call)
	{
		FloodAbilitySystem.CallServerTryActivateAbilityForTests(FloodFixture.ProbeHandle);
	}
	FloodAbilitySystem.ProvisionalActivationBucketRefillPerSecond = 1.0f;
	TestWorld.World->RealTimeSeconds += 1.0;
	ExpectResult(*this, TEXT("The first admitted request after the flood"), FloodFixture.Submit(7, ProbeId(), EPhase::Release), EResult::Accepted);

	TestTrue(TEXT("Flood dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("A flood gives one entry event plus the admitted request's event"), FloodSink->GetEvents().Num(), 2);
	ExpectEvent(*this, FloodSink->GetEvents(), 0, ECategory::Rejection, ECategory::Ability, EReason::RateLimited, 2, FString(), FString());
	ExpectEvent(*this, FloodSink->GetEvents(), 1, ECategory::Ability, ECategory::Ability, EReason::Accepted, 7, FloodActivationId, ProbeIdString);
	TestEqual(TEXT("A flood gives an entry metric, an aggregated exit metric, and the admitted request's metric"), FloodSink->GetMetrics().Num(), 3);
	ExpectMetric(*this, FloodSink->GetMetrics(), 0, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 1);
	ExpectMetric(*this, FloodSink->GetMetrics(), 1, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 7);
	ExpectMetric(*this, FloodSink->GetMetrics(), 2, EMetric::EventCount, ECategory::Ability, EReason::Accepted, 1);
	ExpectOutcomes(*this, TEXT("A flood gives one RateLimited outcome on entry"), FloodFixture.Outcomes, { { 2u, EResult::RateLimited }, { 7u, EResult::Accepted } });

	// A window entered by a refused stock-route call, then torn down while limited.
	FloodAbilitySystem.ProvisionalActivationBucketRefillPerSecond = 0.0f;
	TSharedPtr<FSink, ESPMode::ThreadSafe> TeardownSink = MakeShared<FSink, ESPMode::ThreadSafe>(64);
	TestTrue(TEXT("Teardown sink is accepted"), Subsystem->SetTestSink(TeardownSink));
	FloodFixture.Outcomes.Reset();
	FloodAbilitySystem.CallServerTryActivateAbilityForTests(FloodFixture.ProbeHandle);
	ExpectResult(*this, TEXT("Suppressed request (1)"), FloodFixture.Submit(8, ProbeId()), EResult::RateLimited);
	ExpectResult(*this, TEXT("Suppressed request (2)"), FloodFixture.Submit(9, ProbeId()), EResult::RateLimited);
	// Logout: destroying the controller destroys its PlayerState and unregisters the ASC.
	FloodFixture.Player.Controller->Destroy();
	TestTrue(TEXT("Teardown dispatch drains"), Subsystem->WaitForIdleForTests());
	TestEqual(TEXT("A stock-route entry and suppressed requests emit no event"), TeardownSink->GetEvents().Num(), 0);
	TestEqual(TEXT("Entry metric and teardown flush"), TeardownSink->GetMetrics().Num(), 2);
	ExpectMetric(*this, TeardownSink->GetMetrics(), 0, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 1);
	ExpectMetric(*this, TeardownSink->GetMetrics(), 1, EMetric::RejectionCount, ECategory::Ability, EReason::RateLimited, 2);
	TestEqual(TEXT("A stock-route entry sends no outcome"), FloodFixture.Outcomes.Num(), 0);

	Subsystem->ResetSink();
	Subsystem->ResetRestrictedSink();
	Subsystem->ResetRuntimeContext();
	return true;
}

#endif
