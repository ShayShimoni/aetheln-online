#include "Modules/ModuleManager.h"
#include "AethelnReplicationCandidateRuntime.h"

class FGameNetModule final : public IModuleInterface
{
public:
	virtual void StartupModule() override { AethelnReplicationCandidates::Startup(); }
	virtual void ShutdownModule() override { AethelnReplicationCandidates::Shutdown(); }
};

IMPLEMENT_MODULE(FGameNetModule, GameNet);
