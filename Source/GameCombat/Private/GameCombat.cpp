#include "AethelnBasicChainAbility.h"
#include "Engine/Engine.h"
#include "Misc/CoreDelegates.h"
#include "Modules/ModuleManager.h"

/** Copies the chain's definition asset into the class defaults once the engine can load assets (#84). */
class FGameCombatModule : public FDefaultModuleImpl
{
public:
	virtual void StartupModule() override
	{
		if (GEngine != nullptr && GEngine->IsInitialized())
		{
			UAethelnBasicChainAbility::ApplyDefinitionToClassDefaults();
		}
		else
		{
			FCoreDelegates::OnPostEngineInit.AddStatic(&UAethelnBasicChainAbility::ApplyDefinitionToClassDefaults);
		}
	}
};

IMPLEMENT_MODULE(FGameCombatModule, GameCombat);
