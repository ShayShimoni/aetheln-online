#pragma once

#include "Commandlets/Commandlet.h"
#include "AethelnContentValidationCommandlet.generated.h"

/** Produces a fail-closed, machine-readable report without saving or modifying assets. */
UCLASS()
class UAethelnContentValidationCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UAethelnContentValidationCommandlet();

	virtual int32 Main(const FString& Params) override;
};
