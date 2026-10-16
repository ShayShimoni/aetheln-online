#pragma once

#include "AethelnAttackTypes.h"
#include "AethelnPrimaryAssetDefinition.h"
#include "GameplayTagContainer.h"
#include "AethelnAttackDefinition.generated.h"

/** Validation identifiers of an unusable definition asset, written in the grant refusal (#84). */
namespace AethelnAttackDefinitionId
{
	inline constexpr const TCHAR* Missing = TEXT("attack_definition_missing");
	inline constexpr const TCHAR* Invalid = TEXT("attack_definition_invalid");
	inline constexpr const TCHAR* AbilityMismatch = TEXT("attack_definition_ability_mismatch");
}

/**
 * One authored attack (TA-027, docs/animation-and-combat-content-pipeline.md). The server reads it as
 * the authority for windows, volumes, damage and cost; clients may read its windows for presentation
 * only. It never references presentation. The basic chain reads its values from the definition asset
 * DA_SwordShieldBasicChain, which holds the provisional values the owner decided (#84 D3) and replaced the ini
 * section of the chain in the same change.
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
