#pragma once

#if WITH_DEV_AUTOMATION_TESTS

#include "AbilitySystemComponent.h"
#include "CoreMinimal.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GameplayEffect.h"
#include "UObject/Package.h"

namespace AethelnCombatTests
{
	/**
	 * Headless single-authority world for the GAS foundation tests, using the
	 * same harness as the network spike tests. No game mode is registered, so
	 * controllers spawn without a PlayerState; tests attach one explicitly.
	 */
	class FScopedCombatTestWorld
	{
	public:
		FScopedCombatTestWorld()
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
			WorldContext.SetCurrentWorld(World);
			World->InitializeActorsForPlay(FURL());
			World->BeginPlay();
		}

		~FScopedCombatTestWorld()
		{
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
	};

	/** Test-only effect built at runtime, as the engine's own GAS tests do. */
	inline UGameplayEffect* MakeTestEffect(EGameplayEffectDurationType DurationPolicy)
	{
		UGameplayEffect* Effect = NewObject<UGameplayEffect>(GetTransientPackage(), NAME_None, RF_Transient);
		Effect->DurationPolicy = DurationPolicy;
		return Effect;
	}

	/** Applies one instant modifier, standing in for #60's and #21's server effects. */
	inline void ApplyInstantModifier(UAbilitySystemComponent& AbilitySystemComponent, const FGameplayAttribute& Attribute, EGameplayModOp::Type Op, float Magnitude)
	{
		UGameplayEffect* Effect = MakeTestEffect(EGameplayEffectDurationType::Instant);
		FGameplayModifierInfo& Modifier = Effect->Modifiers.AddDefaulted_GetRef();
		Modifier.Attribute = Attribute;
		Modifier.ModifierOp = Op;
		Modifier.ModifierMagnitude = FScalableFloat(Magnitude);
		AbilitySystemComponent.ApplyGameplayEffectToSelf(Effect, 1.0f, AbilitySystemComponent.MakeEffectContext());
	}
}

#endif
