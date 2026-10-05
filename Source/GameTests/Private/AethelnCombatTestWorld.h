#pragma once

#if WITH_DEV_AUTOMATION_TESTS

#include "AbilitySystemComponent.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnCombatEffects.h"
#include "AethelnCombatTestAbilities.h"
#include "AethelnPlayerState.h"
#include "CoreMinimal.h"
#include "Engine/Engine.h"
#include "Engine/GameInstance.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameplayEffect.h"
#include "Misc/AutomationTest.h"
#include "UObject/Package.h"

namespace AethelnCombatTests
{
	/**
	 * Headless single-authority world for the GAS foundation tests, using the
	 * same harness as the network spike tests. No game mode is registered, so
	 * controllers spawn without a PlayerState; tests attach one explicitly. With
	 * bWithGameInstance the world also gets a game instance, as the spike test
	 * does, so the observability subsystem exists.
	 */
	class FScopedCombatTestWorld
	{
	public:
		explicit FScopedCombatTestWorld(bool bWithGameInstance = false)
		{
			World = UWorld::CreateWorld(EWorldType::Game, false);
			if (World == nullptr)
			{
				return;
			}
			if (GEngine == nullptr)
			{
				World->DestroyWorld(false);
				World = nullptr;
				return;
			}
			FWorldContext& WorldContext = GEngine->CreateNewWorldContext(EWorldType::Game);
			if (bWithGameInstance)
			{
				GameInstance = NewObject<UGameInstance>(GEngine);
				WorldContext.OwningGameInstance = GameInstance;
				World->SetGameInstance(GameInstance);
			}
			WorldContext.SetCurrentWorld(World);
			if (GameInstance != nullptr)
			{
				GameInstance->Init();
			}
			World->InitializeActorsForPlay(FURL());
			World->BeginPlay();
		}

		~FScopedCombatTestWorld()
		{
			if (GameInstance != nullptr)
			{
				GameInstance->Shutdown();
			}
			if (World != nullptr)
			{
				World->DestroyWorld(false);
				GEngine->DestroyWorldContext(World);
			}
		}

		template <typename T>
		T* Spawn(AActor* Owner = nullptr) const
		{
			FActorSpawnParameters SpawnParameters;
			SpawnParameters.Owner = Owner;
			SpawnParameters.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
			return World->SpawnActor<T>(T::StaticClass(), FVector::ZeroVector, FRotator::ZeroRotator, SpawnParameters);
		}

		UWorld* World = nullptr;
		UGameInstance* GameInstance = nullptr;
	};

	/** Test-only effect built at runtime, as the engine's own GAS tests do. */
	inline UGameplayEffect* MakeTestEffect(EGameplayEffectDurationType DurationPolicy)
	{
		UGameplayEffect* Effect = NewObject<UGameplayEffect>(GetTransientPackage(), NAME_None, RF_Transient);
		Effect->DurationPolicy = DurationPolicy;
		return Effect;
	}

	/** Applies one modifier through a runtime effect, standing in for #60's and #21's server effects. */
	inline FActiveGameplayEffectHandle ApplyModifier(UAbilitySystemComponent& AbilitySystemComponent, EGameplayEffectDurationType DurationPolicy, const FGameplayAttribute& Attribute, EGameplayModOp::Type Op, float Magnitude)
	{
		UGameplayEffect* Effect = MakeTestEffect(DurationPolicy);
		FGameplayModifierInfo& Modifier = Effect->Modifiers.AddDefaulted_GetRef();
		Modifier.Attribute = Attribute;
		Modifier.ModifierOp = Op;
		Modifier.ModifierMagnitude = FScalableFloat(Magnitude);
		return AbilitySystemComponent.ApplyGameplayEffectToSelf(Effect, 1.0f, AbilitySystemComponent.MakeEffectContext());
	}

	inline void ApplyInstantModifier(UAbilitySystemComponent& AbilitySystemComponent, const FGameplayAttribute& Attribute, EGameplayModOp::Type Op, float Magnitude)
	{
		ApplyModifier(AbilitySystemComponent, EGameplayEffectDurationType::Instant, Attribute, Op, Magnitude);
	}

	/** Test-pinned values, not tuning. Each current value equals its maximum so a wrong init order would clamp it to 0. */
	inline FAethelnCombatAttributeInitValues MakeTestInitValues()
	{
		FAethelnCombatAttributeInitValues Values;
		Values.MaxHealth = 40.0f;
		Values.Health = 40.0f;
		Values.MaxEndurance = 30.0f;
		Values.Endurance = 30.0f;
		Values.MaxGuard = 20.0f;
		Values.Guard = 20.0f;
		return Values;
	}

	struct FTestPlayer
	{
		APlayerController* Controller = nullptr;
		AAethelnPlayerState* PlayerState = nullptr;
		UAethelnAbilitySystemComponent* AbilitySystem = nullptr;
	};

	/**
	 * A controller with a fresh AAethelnPlayerState, configured with test values and
	 * the given abilities. The test-pinned rate bucket (1000 tokens, no refill) never
	 * limits a test unless the test sets its own.
	 */
	inline AAethelnPlayerState* AttachFreshPlayerState(
		const FScopedCombatTestWorld& TestWorld,
		APlayerController& Controller,
		const TArray<TSubclassOf<UGameplayAbility>>& Abilities = { UAethelnLongRunningTestAbility::StaticClass() })
	{
		AAethelnPlayerState* PlayerState = TestWorld.Spawn<AAethelnPlayerState>(&Controller);
		if (PlayerState != nullptr)
		{
			PlayerState->GrantedAbilities = Abilities;
			PlayerState->ProvisionalInitialAttributes = MakeTestInitValues();
			PlayerState->GetAethelnAbilitySystemComponent()->ProvisionalActivationBucketCapacity = 1000.0f;
			PlayerState->GetAethelnAbilitySystemComponent()->ProvisionalActivationBucketRefillPerSecond = 0.0f;
			Controller.SetPlayerState(PlayerState);
		}
		return PlayerState;
	}

	inline bool SpawnTestPlayer(
		FAutomationTestBase& Test,
		const FScopedCombatTestWorld& TestWorld,
		FTestPlayer& OutPlayer,
		const TArray<TSubclassOf<UGameplayAbility>>& Abilities = { UAethelnLongRunningTestAbility::StaticClass() })
	{
		if (!Test.TestNotNull(TEXT("Test world exists"), TestWorld.World))
		{
			return false;
		}
		OutPlayer.Controller = TestWorld.Spawn<APlayerController>();
		if (!Test.TestNotNull(TEXT("Player controller exists"), OutPlayer.Controller))
		{
			return false;
		}
		Test.TestNull(TEXT("The harness registers no game mode, so the controller starts without a PlayerState"), OutPlayer.Controller->PlayerState.Get());
		OutPlayer.PlayerState = AttachFreshPlayerState(TestWorld, *OutPlayer.Controller, Abilities);
		if (!Test.TestNotNull(TEXT("AAethelnPlayerState exists"), OutPlayer.PlayerState))
		{
			return false;
		}
		OutPlayer.AbilitySystem = OutPlayer.PlayerState->GetAethelnAbilitySystemComponent();
		return Test.TestNotNull(TEXT("PlayerState owns the project ASC"), OutPlayer.AbilitySystem);
	}
}

#endif
