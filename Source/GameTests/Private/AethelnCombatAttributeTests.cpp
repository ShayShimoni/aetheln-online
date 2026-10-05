#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatAICharacter.h"
#include "AethelnCombatAttributeSet.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnPlayerCharacter.h"
#include "AethelnPlayerState.h"
#include "GameFramework/PlayerController.h"
#include "Misc/AutomationTest.h"
#include "UObject/CoreNet.h"

namespace AethelnCombatAttributeTests
{
	struct FBoundedPair
	{
		const TCHAR* Name;
		FGameplayAttribute Current;
		FGameplayAttribute Max;
	};

	TArray<FBoundedPair> GetBoundedPairs()
	{
		return {
			{ TEXT("Health"), UAethelnCombatAttributeSet::GetHealthAttribute(), UAethelnCombatAttributeSet::GetMaxHealthAttribute() },
			{ TEXT("Endurance"), UAethelnCombatAttributeSet::GetEnduranceAttribute(), UAethelnCombatAttributeSet::GetMaxEnduranceAttribute() },
			{ TEXT("Guard"), UAethelnCombatAttributeSet::GetGuardAttribute(), UAethelnCombatAttributeSet::GetMaxGuardAttribute() },
		};
	}

	using AethelnCombatTests::MakeTestInitValues;

	float GetValue(const UAbilitySystemComponent& AbilitySystem, const FGameplayAttribute& Attribute)
	{
		return AbilitySystem.GetNumericAttribute(Attribute);
	}

	void TestAllValues(FAutomationTestBase& Test, const TCHAR* Context, const UAbilitySystemComponent& AbilitySystem, const FAethelnCombatAttributeInitValues& Expected)
	{
		Test.TestEqual(*FString::Printf(TEXT("%s: MaxHealth"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetMaxHealthAttribute()), Expected.MaxHealth);
		Test.TestEqual(*FString::Printf(TEXT("%s: Health"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetHealthAttribute()), Expected.Health);
		Test.TestEqual(*FString::Printf(TEXT("%s: MaxEndurance"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetMaxEnduranceAttribute()), Expected.MaxEndurance);
		Test.TestEqual(*FString::Printf(TEXT("%s: Endurance"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetEnduranceAttribute()), Expected.Endurance);
		Test.TestEqual(*FString::Printf(TEXT("%s: MaxGuard"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetMaxGuardAttribute()), Expected.MaxGuard);
		Test.TestEqual(*FString::Printf(TEXT("%s: Guard"), Context), GetValue(AbilitySystem, UAethelnCombatAttributeSet::GetGuardAttribute()), Expected.Guard);
	}
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAttributeReplicationPolicyTest,
	"Aetheln.GameCombat.Attributes.ReplicationPolicy",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttributeReplicationPolicyTest::RunTest(const FString& Parameters)
{
	// Rep indices are assigned lazily (normally by the first net driver), so set them up first.
	UAethelnCombatAttributeSet::StaticClass()->SetUpRuntimeReplicationData();
	TArray<FLifetimeProperty> LifetimeProperties;
	GetDefault<UAethelnCombatAttributeSet>()->GetLifetimeReplicatedProps(LifetimeProperties);

	int32 ReplicatedAttributeCount = 0;
	for (const TCHAR* Name : { TEXT("Health"), TEXT("MaxHealth"), TEXT("Endurance"), TEXT("MaxEndurance"), TEXT("Guard"), TEXT("MaxGuard") })
	{
		const FProperty* Property = FindFProperty<FProperty>(UAethelnCombatAttributeSet::StaticClass(), Name);
		if (!TestNotNull(*FString::Printf(TEXT("%s is a reflected property"), Name), Property))
		{
			continue;
		}
		const FLifetimeProperty* LifetimeProperty = LifetimeProperties.FindByPredicate(
			[Property](const FLifetimeProperty& Candidate) { return Candidate.RepIndex == Property->RepIndex; });
		if (!TestNotNull(*FString::Printf(TEXT("%s replicates"), Name), LifetimeProperty))
		{
			continue;
		}
		++ReplicatedAttributeCount;
		TestTrue(*FString::Printf(TEXT("%s replicates to the owner only"), Name), LifetimeProperty->Condition == COND_OwnerOnly);
		TestTrue(*FString::Printf(TEXT("%s always fires its RepNotify"), Name), LifetimeProperty->RepNotifyCondition == REPNOTIFY_Always);
	}
	TestEqual(TEXT("All six attributes replicate"), ReplicatedAttributeCount, 6);
	TestEqual(TEXT("The set replicates nothing else"), LifetimeProperties.Num(), 6);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAttributeClampAndBoundsTest,
	"Aetheln.GameCombat.Attributes.ClampAndBounds",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttributeClampAndBoundsTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCombatAttributeTests;

	AethelnCombatTests::FScopedCombatTestWorld TestWorld;
	if (!TestNotNull(TEXT("Test world exists"), TestWorld.World))
	{
		return false;
	}
	AAethelnCombatAICharacter* Character = TestWorld.Spawn<AAethelnCombatAICharacter>();
	if (!TestNotNull(TEXT("Character with the combat attribute set exists"), Character))
	{
		return false;
	}
	UAethelnAbilitySystemComponent* AbilitySystem = Character->GetAethelnAbilitySystemComponent();
	UAethelnAttributeInitEffect::ApplyTo(*AbilitySystem, MakeTestInitValues());
	TestAllValues(*this, TEXT("Test init"), *AbilitySystem, MakeTestInitValues());

	for (const FBoundedPair& Pair : GetBoundedPairs())
	{
		const float Max = GetValue(*AbilitySystem, Pair.Max);

		// A duration modifier never touches the base, so only the current-value
		// clamp (PreAttributeChange) can hold the current value at its maximum.
		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Current, EGameplayModOp::AddBase, -Max * 0.25f);
		const FActiveGameplayEffectHandle BuffHandle = AethelnCombatTests::ApplyModifier(
			*AbilitySystem, EGameplayEffectDurationType::Infinite, Pair.Current, EGameplayModOp::AddBase, 1000.0f);
		TestEqual(*FString::Printf(TEXT("A duration modifier clamps %s to its maximum"), Pair.Name), GetValue(*AbilitySystem, Pair.Current), Max);
		TestEqual(*FString::Printf(TEXT("A duration modifier leaves the %s base unchanged"), Pair.Name), AbilitySystem->GetNumericAttributeBase(Pair.Current), Max * 0.75f);
		TestTrue(*FString::Printf(TEXT("The %s duration modifier is removed"), Pair.Name), AbilitySystem->RemoveActiveGameplayEffect(BuffHandle));
		TestEqual(*FString::Printf(TEXT("%s returns to its base when the modifier ends"), Pair.Name), GetValue(*AbilitySystem, Pair.Current), Max * 0.75f);

		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Current, EGameplayModOp::AddBase, 1000.0f);
		TestEqual(*FString::Printf(TEXT("%s clamps to its maximum"), Pair.Name), GetValue(*AbilitySystem, Pair.Current), Max);
		TestEqual(*FString::Printf(TEXT("The %s base clamps to its maximum"), Pair.Name), AbilitySystem->GetNumericAttributeBase(Pair.Current), Max);

		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Current, EGameplayModOp::AddBase, -1000.0f);
		TestEqual(*FString::Printf(TEXT("%s clamps to 0"), Pair.Name), GetValue(*AbilitySystem, Pair.Current), 0.0f);
		TestEqual(*FString::Printf(TEXT("The %s base clamps to 0"), Pair.Name), AbilitySystem->GetNumericAttributeBase(Pair.Current), 0.0f);

		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Current, EGameplayModOp::AddBase, 1000.0f);
		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Max, EGameplayModOp::Override, Max * 0.5f);
		TestEqual(*FString::Printf(TEXT("Lowering Max%s lowers it"), Pair.Name), GetValue(*AbilitySystem, Pair.Max), Max * 0.5f);
		TestEqual(*FString::Printf(TEXT("Lowering Max%s re-clamps %s"), Pair.Name, Pair.Name), GetValue(*AbilitySystem, Pair.Current), Max * 0.5f);

		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Max, EGameplayModOp::Override, Max);
		TestEqual(*FString::Printf(TEXT("Raising Max%s never scales %s up"), Pair.Name, Pair.Name), GetValue(*AbilitySystem, Pair.Current), Max * 0.5f);

		AethelnCombatTests::ApplyInstantModifier(*AbilitySystem, Pair.Max, EGameplayModOp::Override, -5.0f);
		TestEqual(*FString::Printf(TEXT("Max%s clamps to 0"), Pair.Name), GetValue(*AbilitySystem, Pair.Max), 0.0f);
		TestEqual(*FString::Printf(TEXT("%s follows a zero maximum"), Pair.Name), GetValue(*AbilitySystem, Pair.Current), 0.0f);
	}

	// The re-clamp writes only on the server. A client reaches PostAttributeChange
	// when a lowered maximum replicates; simulate that role and call it directly.
	UAethelnAttributeInitEffect::ApplyTo(*AbilitySystem, MakeTestInitValues());
	UAethelnCombatAttributeSet* AttributeSet = const_cast<UAethelnCombatAttributeSet*>(Character->GetCombatAttributeSet());
	const FGameplayAttribute HealthAttribute = UAethelnCombatAttributeSet::GetHealthAttribute();
	const FGameplayAttribute MaxHealthAttribute = UAethelnCombatAttributeSet::GetMaxHealthAttribute();
	const float FullHealth = MakeTestInitValues().Health;
	const float LoweredMax = FullHealth * 0.5f;

	Character->SetRole(ROLE_SimulatedProxy);
	AbilitySystem->CacheIsNetSimulated();
	TestFalse(TEXT("Simulated proxy ASC is not authoritative"), AbilitySystem->IsOwnerActorAuthoritative());
	AttributeSet->PostAttributeChange(MaxHealthAttribute, FullHealth, LoweredMax);
	TestEqual(TEXT("Client re-clamp writes nothing to the Health base"), AbilitySystem->GetNumericAttributeBase(HealthAttribute), FullHealth);

	Character->SetRole(ROLE_Authority);
	AbilitySystem->CacheIsNetSimulated();
	TestTrue(TEXT("Restored ASC is authoritative"), AbilitySystem->IsOwnerActorAuthoritative());
	AttributeSet->PostAttributeChange(MaxHealthAttribute, FullHealth, LoweredMax);
	TestEqual(TEXT("Server re-clamp lowers the Health base"), AbilitySystem->GetNumericAttributeBase(HealthAttribute), LoweredMax);
	return true;
}

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnAttributeInitOnceThroughEffectTest,
	"Aetheln.GameCombat.Attributes.InitOnceThroughEffect",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnAttributeInitOnceThroughEffectTest::RunTest(const FString& Parameters)
{
	using namespace AethelnCombatAttributeTests;

	AethelnCombatTests::FScopedCombatTestWorld TestWorld;
	if (!TestNotNull(TEXT("Test world exists"), TestWorld.World))
	{
		return false;
	}
	APlayerController* Controller = TestWorld.Spawn<APlayerController>();
	AAethelnPlayerState* PlayerState = Controller != nullptr ? TestWorld.Spawn<AAethelnPlayerState>(Controller) : nullptr;
	AAethelnPlayerCharacter* Pawn = TestWorld.Spawn<AAethelnPlayerCharacter>();
	if (!TestNotNull(TEXT("Player controller exists"), Controller)
		|| !TestNotNull(TEXT("PlayerState exists"), PlayerState)
		|| !TestNotNull(TEXT("Pawn exists"), Pawn))
	{
		return false;
	}
	Controller->SetPlayerState(PlayerState);
	PlayerState->ProvisionalInitialAttributes = MakeTestInitValues();
	UAethelnAbilitySystemComponent* AbilitySystem = PlayerState->GetAethelnAbilitySystemComponent();

	TestAllValues(*this, TEXT("Before possession nothing has been applied"), *AbilitySystem, FAethelnCombatAttributeInitValues());

	int32 InitEffectApplications = 0;
	AbilitySystem->OnGameplayEffectAppliedDelegateToSelf.AddLambda(
		[&InitEffectApplications](UAbilitySystemComponent*, const FGameplayEffectSpec& Spec, FActiveGameplayEffectHandle)
		{
			if (Spec.Def != nullptr && Spec.Def->GetClass() == UAethelnAttributeInitEffect::StaticClass())
			{
				++InitEffectApplications;
			}
		});

	Controller->Possess(Pawn);
	TestEqual(TEXT("The init effect is applied on the first possession"), InitEffectApplications, 1);
	TestAllValues(*this, TEXT("After the first possession every value equals its configured value"), *AbilitySystem, MakeTestInitValues());

	// Changed config must not reach an already initialized PlayerState.
	FAethelnCombatAttributeInitValues ChangedValues = MakeTestInitValues();
	ChangedValues.MaxHealth += 5.0f;
	ChangedValues.Health += 5.0f;
	PlayerState->ProvisionalInitialAttributes = ChangedValues;
	Controller->UnPossess();
	Controller->Possess(Pawn);
	TestEqual(TEXT("Re-possession does not reapply the init effect"), InitEffectApplications, 1);
	TestAllValues(*this, TEXT("After re-possession values are unchanged"), *AbilitySystem, MakeTestInitValues());
	return true;
}

#endif
