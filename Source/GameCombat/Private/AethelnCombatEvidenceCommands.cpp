#if !UE_BUILD_SHIPPING

#include "Abilities/GameplayAbility.h"
#include "AethelnAbilitySystemComponent.h"
#include "AethelnPlayerState.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "GameplayTagContainer.h"
#include "HAL/IConsoleManager.h"

/**
 * Two-client evidence commands for Issue #19 P5 (docs/gas-foundation.md, T23 to T28). Ability input
 * bindings belong to #60 and #82, so until they land this is the only way to start an ability by hand.
 * Both commands call existing client entry points; neither adds authority or bypasses a server check.
 */
DEFINE_LOG_CATEGORY_STATIC(LogAethelnCombatEvidence, Log, All);

namespace
{
	UAethelnAbilitySystemComponent* FindLocalAbilitySystem(UWorld* World)
	{
		const APlayerController* Controller = World != nullptr ? World->GetFirstPlayerController() : nullptr;
		const AAethelnPlayerState* PlayerState = Controller != nullptr ? Controller->GetPlayerState<AAethelnPlayerState>() : nullptr;
		return PlayerState != nullptr ? PlayerState->GetAethelnAbilitySystemComponent() : nullptr;
	}

	void RequestFromConsole(const TArray<FString>& Args, UWorld* World)
	{
		UAethelnAbilitySystemComponent* AbilitySystem = FindLocalAbilitySystem(World);
		const FGameplayTag AbilityId = Args.Num() > 0 ? FGameplayTag::RequestGameplayTag(FName(*Args[0]), false) : FGameplayTag();
		if (AbilitySystem == nullptr || !AbilityId.IsValid())
		{
			UE_LOG(LogAethelnCombatEvidence, Warning, TEXT("Usage: Aetheln.Combat.Request <AbilityId> [Press|Release]. Needs a local player with an Aetheln PlayerState and a valid ability tag."));
			return;
		}
		const bool bRelease = Args.Num() > 1 && Args[1].Equals(TEXT("Release"), ESearchCase::IgnoreCase);
		UE_LOG(LogAethelnCombatEvidence, Log, TEXT("Requesting %s %s"), *AbilityId.ToString(), bRelease ? TEXT("Release") : TEXT("Press"));
		AbilitySystem->RequestActivation(AbilityId, bRelease ? EAethelnActivationPhase::Release : EAethelnActivationPhase::Press);
	}

	/** T27: the stock client routes. Activates and commits nothing; the log shows what the client sees. */
	void DirectFromConsole(UWorld* World)
	{
		UAethelnAbilitySystemComponent* AbilitySystem = FindLocalAbilitySystem(World);
		if (AbilitySystem == nullptr)
		{
			UE_LOG(LogAethelnCombatEvidence, Warning, TEXT("Aetheln.Combat.Direct needs a local player with an Aetheln PlayerState."));
			return;
		}
		for (const FGameplayAbilitySpec& Spec : AbilitySystem->GetActivatableAbilities())
		{
			const bool bCanActivate = Spec.Ability != nullptr && Spec.Ability->CanActivateAbility(Spec.Handle, AbilitySystem->AbilityActorInfo.Get());
			const bool bTryActivate = AbilitySystem->TryActivateAbility(Spec.Handle);
			UE_LOG(LogAethelnCombatEvidence, Log, TEXT("Direct %s: CanActivateAbility=%d TryActivateAbility=%d"), *GetNameSafe(Spec.Ability), bCanActivate, bTryActivate);
#if WITH_DEV_AUTOMATION_TESTS
			AbilitySystem->CallServerTryActivateAbilityForTests(Spec.Handle);
			UE_LOG(LogAethelnCombatEvidence, Log, TEXT("Direct %s: engine ServerTryActivateAbility RPC sent"), *GetNameSafe(Spec.Ability));
#endif
		}
	}

	FAutoConsoleCommandWithWorldAndArgs GRequestCommand(
		TEXT("Aetheln.Combat.Request"),
		TEXT("Start an ability through the activation seam. Usage: Aetheln.Combat.Request <AbilityId> [Press|Release]"),
		FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(&RequestFromConsole));

	FAutoConsoleCommandWithWorld GDirectCommand(
		TEXT("Aetheln.Combat.Direct"),
		TEXT("Call the stock client activation routes for every granted ability; the server must refuse them."),
		FConsoleCommandWithWorldDelegate::CreateStatic(&DirectFromConsole));
}

#endif
