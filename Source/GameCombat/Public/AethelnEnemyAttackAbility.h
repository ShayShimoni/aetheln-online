#pragma once

#include "AethelnAttackTypes.h"
#include "AethelnGameplayAbility.h"
#include "AethelnEnemyAttackAbility.generated.h"

/**
 * The prototype enemy's one attack (docs/enemy-ai-and-navigation.md). It is never activated: the enemy
 * controller registers its step on the #60 timeline directly. Granting it gives the timeline the ability id
 * and content version it revalidates contacts against, and clients read the same config to derive the
 * attack phases. Every value is TBD (#107, #45); unset config fails the grant, so the enemy never attacks.
 */
UCLASS(Config = Game)
class GAMECOMBAT_API UAethelnEnemyAttackAbility : public UAethelnGameplayAbility
{
	GENERATED_BODY()

public:
	UAethelnEnemyAttackAbility();

	/** The base rules, no cost, cooldown, or Release, valid sampling bounds, and one final-form step. */
	virtual const TCHAR* FindGrantProblem() const override;

	/** Always false: no GAS route activates this ability. */
	virtual bool CanActivateAbility(FGameplayAbilitySpecHandle Handle, const FGameplayAbilityActorInfo* ActorInfo, const FGameplayTagContainer* SourceTags = nullptr, const FGameplayTagContainer* TargetTags = nullptr, FGameplayTagContainer* OptionalRelevantTags = nullptr) const override;

	/** The one step, in final form: BufferOpen equals RecoveryEnd and there is no link window. */
	UPROPERTY(Config) FAethelnAttackStepDefinition ProvisionalStep;
	UPROPERTY(Config) double ProvisionalMaxSampleDistance = 0.0;
	UPROPERTY(Config) double ProvisionalMaxSampleAngleDegrees = 0.0;
};
