#include "Modules/ModuleManager.h"

IMPLEMENT_MODULE(FDefaultModuleImpl, GameTests);

#if WITH_DEV_AUTOMATION_TESTS

#include "Misc/App.h"
#include "Misc/AutomationTest.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnProjectAndModuleLoadTest,
	"Aetheln.Harness.ProjectAndModuleLoad",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnProjectAndModuleLoadTest::RunTest(const FString& Parameters)
{
	TestEqual(TEXT("Expected project is loaded"), FString(FApp::GetProjectName()), FString(TEXT("AethelnOnline")));
	TestTrue(TEXT("GameCore runtime module is loaded"), FModuleManager::Get().IsModuleLoaded(FName(TEXT("GameCore"))));
	TestTrue(TEXT("GameTests editor module is loaded"), FModuleManager::Get().IsModuleLoaded(FName(TEXT("GameTests"))));
	return true;
}

#endif
