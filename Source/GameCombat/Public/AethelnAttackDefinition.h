#pragma once

#include "AethelnAttackTypes.h"
#include "AethelnPrimaryAssetDefinition.h"
#include "GameplayTagContainer.h"
#include "AethelnAttackDefinition.generated.h"

/**
 * One authored attack (TA-027, docs/animation-and-combat-content-pipeline.md). The server reads it as
 * the authority for windows, volumes, damage and cost; clients may read its windows for presentation
 * only. It never references presentation. Every value is TBD until an owner decision, and no attack is
 * migrated to it yet: the chain still reads its ini values.
 */
UCLASS(BlueprintType)
class GAMECOMBAT_API UAethelnAttackDefinition : public UAethelnPrimaryAssetDefinition
{
	GENERATED_BODY()

public:
	/** The request AbilityId this definition serves. Maps one to one to StableContentId (the registry semantic ID). */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Attack")
	FGameplayTag AbilityId;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Attack")
	TArray<FAethelnAttackStepDefinition> Steps;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Attack")
	double MaxSampleDistance = 0.0;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Attack")
	double MaxSampleAngleDegrees = 0.0;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Attack")
	float EnduranceCost = 0.0f;

	/** Fails closed: nullptr only for a complete, Shared, versioned definition with valid steps. */
	const TCHAR* FindProblem() const;

#if WITH_EDITOR
	virtual EDataValidationResult IsDataValid(FDataValidationContext& Context) const override;
#endif
};
