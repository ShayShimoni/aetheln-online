#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnSpikeAuthorityComponent.h"
#include "AethelnSpikeAuthorityTypes.h"
#include "AethelnSpikeEnemy.h"
#include "AethelnSpikeMeleeAbility.h"
#include "AbilitySystemComponent.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "Misc/AutomationTest.h"
#include "UObject/UnrealType.h"

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

	UAethelnSpikeAuthorityComponent* AuthorityComponent = NewObject<UAethelnSpikeAuthorityComponent>(Attacker, TEXT("TestAuthorityComponent"));
	AuthorityComponent->RegisterComponent();
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

	FAethelnSpikeAttackIntent Intent;
	Intent.Sequence = 1;
	Intent.ClientTimestampSeconds = World->GetTimeSeconds();
	Intent.Aim = -FVector::ForwardVector;

	const float InitialHealth = Target->GetHealth();
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Client aim conflicting with authoritative view is rejected"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ImpossibleAimTransition);
	TestEqual(TEXT("Impossible aim transition causes no damage"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Impossible aim transition never opens the attack window"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Impossible aim transition creates no activation identity"), AuthorityComponent->GetActiveAttackId().IsValid());

	Intent.Aim = FVector::ForwardVector;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Unavailable GAS ability has a truthful refusal"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::ActivationBlocked);
	TestEqual(TEXT("Activation refusal causes no damage"), Target->GetHealth(), InitialHealth);
	TestFalse(TEXT("Activation refusal closes the authored attack window"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Activation refusal retires the activation identity"), AuthorityComponent->GetActiveAttackId().IsValid());

	AttackerAbilitySystem->GiveAbility(FGameplayAbilitySpec(UAethelnSpikeMeleeAbility::StaticClass(), 1));
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("The refused sequence remains retryable after the GAS block clears"), Target->GetHealth(), InitialHealth - 25.0f);
	TestEqual(TEXT("Successful retry clears the refusal"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::None);
	TestFalse(TEXT("Authored attack window closes after resolution"), AuthorityComponent->IsAttackWindowActive());
	TestFalse(TEXT("Activation identity is retired with its window"), AuthorityComponent->GetActiveAttackId().IsValid());

	const float HealthAfterFirstActivation = Target->GetHealth();
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Accepted sequence becomes a duplicate"), AuthorityComponent->GetLastRejection(), EAethelnSpikeAttackRejection::DuplicateSequence);
	TestEqual(TEXT("Duplicate command cannot deal additional damage"), Target->GetHealth(), HealthAfterFirstActivation);

	Intent.Sequence = 2;
	Intent.SchemaVersion = 2;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Invalid version causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	Intent.SchemaVersion = 1;

	Intent.Sequence = 3;
	Intent.Aim = FVector::ZeroVector;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Invalid aim causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	Intent.Aim = FVector::ForwardVector;

	AuthorityComponent->SetLifecycleReady(false);
	Intent.Sequence = 4;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Closed lifecycle causes no damage"), Target->GetHealth(), HealthAfterFirstActivation);
	AuthorityComponent->SetLifecycleReady(true);

	const float HealthBeforeDestroyedTargetRequest = Target->GetHealth();
	Target->Destroy();
	Intent.Sequence = 5;
	AuthorityComponent->ProcessServerIntent(Intent);
	TestEqual(TEXT("Destroyed target receives no further effect"), Target->GetHealth(), HealthBeforeDestroyedTargetRequest);

	World->DestroyWorld(false);
	GEngine->DestroyWorldContext(World);
	return true;
}

#endif
