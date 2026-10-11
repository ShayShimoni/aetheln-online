#if WITH_DEV_AUTOMATION_TESTS

#include "AethelnCombatGameMode.h"
#include "AethelnCombatTestWorld.h"
#include "AethelnPlayerCharacter.h"
#include "GameFramework/Pawn.h"
#include "Misc/AutomationTest.h"
#include "Misc/ConfigCacheIni.h"

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnCombatGameModeSelectsInputEnabledPawnTest,
	"Aetheln.GameCombat.GameMode.SelectsInputEnabledPawn",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnCombatGameModeSelectsInputEnabledPawnTest::RunTest(const FString& Parameters)
{
	// The ini section loads: the header default is empty, so only config can fill the class default.
	FString IniPath;
	TestTrue(TEXT("DefaultGame.ini sets InputEnabledPawnClass"),
		GConfig->GetString(TEXT("/Script/GameCombat.AethelnCombatGameMode"), TEXT("InputEnabledPawnClass"), IniPath, GGameIni));
	TestFalse(TEXT("The class default loaded the ini value"), GetDefault<AAethelnCombatGameMode>()->InputEnabledPawnClass.IsNull());

	AethelnCombatTests::FScopedCombatTestWorld TestWorld;
	AAethelnCombatGameMode* GameMode = TestWorld.Spawn<AAethelnCombatGameMode>();
	if (!TestNotNull(TEXT("Combat game mode spawns"), GameMode))
	{
		return false;
	}

	// The configured generated Blueprint loads and is the GameCore pawn with the client POC input component.
	UClass* SelectedClass = GameMode->GetDefaultPawnClassForController(nullptr);
	if (!TestNotNull(TEXT("A pawn class is selected"), SelectedClass))
	{
		return false;
	}
	TestTrue(TEXT("The configured soft class is the one selected"), SelectedClass == GameMode->InputEnabledPawnClass.Get());
	TestTrue(TEXT("The selected pawn derives from the GameCore player character"), SelectedClass->IsChildOf(AAethelnPlayerCharacter::StaticClass()));
	const FClassProperty* InputComponentProperty = CastField<FClassProperty>(FindFProperty<FProperty>(APawn::StaticClass(), TEXT("OverrideInputComponentClass")));
	if (TestNotNull(TEXT("APawn reflects OverrideInputComponentClass"), InputComponentProperty))
	{
		const UObject* InputComponentClass = InputComponentProperty->GetObjectPropertyValue_InContainer(SelectedClass->GetDefaultObject());
		TestEqual(TEXT("The selected pawn carries the POC input component"), GetNameSafe(InputComponentClass), FString(TEXT("AethelnPOCInputComponent")));
	}

	// Without a configured class the inherited default pawn class stays.
	GameMode->InputEnabledPawnClass.Reset();
	TestTrue(TEXT("An empty path keeps DefaultPawnClass"), GameMode->GetDefaultPawnClassForController(nullptr) == GameMode->DefaultPawnClass.Get());
	return true;
}

#endif
