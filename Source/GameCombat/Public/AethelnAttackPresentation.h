#pragma once

#include "AethelnPrimaryAssetDefinition.h"
#include "GameplayTagContainer.h"
#include "AethelnAttackPresentation.generated.h"

class UAethelnAttackDefinition;
class UAnimMontage;
class USkeleton;
struct FAssetData;

/** The outcome of looking up the binding of one ability and definition version. */
enum class EAethelnPresentationLookup : uint8
{
	/** Exactly one binding. */
	Found,
	/** No binding is mounted for that ability and version; presentation falls back to the neutral one. */
	NotFound,
	/** Two or more bindings claim the ability and version. A validation error, never a priority rule. */
	Ambiguous
};

/** The presentation of one attack step. The montage sections map onto the step's authored windows; they never define them. */
USTRUCT()
struct GAMECOMBAT_API FAethelnAttackPresentationStep
{
	GENERATED_BODY()
	UPROPERTY(EditAnywhere) TObjectPtr<UAnimMontage> Montage;
	UPROPERTY(EditAnywhere) FName WindUpSection;
	UPROPERTY(EditAnywhere) FName ActiveSection;
	UPROPERTY(EditAnywhere) FName RecoverySection;
	/** Skeleton sockets used for trails and effects. */
	UPROPERTY(EditAnywhere) TArray<FName> Sockets;
};

/**
 * The client-only presentation binding of one attack (#84 P3, docs/animation-and-combat-content-pipeline.md).
 * It names the definition it was authored against and may hard-reference it (client_only to shared is
 * allowed); the definition never references it. It is presentation only: nothing here opens a window, creates
 * a contact, applies damage or a cost, or writes persistence, and changing it never changes a content version.
 */
UCLASS(BlueprintType)
class GAMECOMBAT_API UAethelnAttackPresentation : public UAethelnPrimaryAssetDefinition
{
	GENERATED_BODY()

public:
	/** The ability this binding presents. Must equal Definition->AbilityId. */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Presentation")
	FGameplayTag AbilityId;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Presentation")
	TObjectPtr<UAethelnAttackDefinition> Definition;

	/** The definition ContentVersion this binding was authored against. A different definition version makes it stale. */
	UPROPERTY(EditDefaultsOnly, AssetRegistrySearchable, Category = "Aetheln|Presentation", meta = (ClampMin = "1", UIMin = "1"))
	int32 AuthoredContentVersion = 0;

	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Presentation")
	TObjectPtr<USkeleton> Skeleton;

	/** One entry per definition step, in step order. */
	UPROPERTY(EditDefaultsOnly, Category = "Aetheln|Presentation")
	TArray<FAethelnAttackPresentationStep> Steps;

	/** Fails closed: nullptr only for a complete, ClientOnly binding that matches its definition and holds only allowlisted notifies. */
	const TCHAR* FindProblem() const;

	/** Initial allowlist of presentation notify classes. Any other class, and a notify with no class, fails. */
	static bool IsPresentationNotifyClass(const UClass* NotifyClass);

	/**
	 * Finds the binding for an ability and the definition version it was authored against with an Asset Registry
	 * query over all mounted content: the binding class plus the searchable AbilityId and AuthoredContentVersion
	 * tags. It never names a package path, so a binding in the private art plugin is found without any public
	 * reference to that plugin (TA-019). OutAsset is set only for Found.
	 */
	static EAethelnPresentationLookup FindBinding(const FGameplayTag& InAbilityId, int32 InAuthoredContentVersion, FAssetData& OutAsset);

	/** AbilityId is a struct, which the Asset Registry would export as an empty value, so it is written as a plain-string tag. */
	virtual void GetAssetRegistryTags(FAssetRegistryTagsContext Context) const override;

#if WITH_EDITOR
	virtual EDataValidationResult IsDataValid(FDataValidationContext& Context) const override;
#endif
};
