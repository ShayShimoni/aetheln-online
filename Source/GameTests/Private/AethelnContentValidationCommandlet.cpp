#include "AethelnContentValidationCommandlet.h"

#include "AethelnContentValidationScanner.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformMisc.h"
#include "Misc/AutomationTest.h"
#include "Misc/FileHelper.h"
#include "Misc/Parse.h"
#include "Misc/Paths.h"

#if PLATFORM_WINDOWS
#include "Windows/WindowsHWrapper.h"
#endif

DEFINE_LOG_CATEGORY_STATIC(LogAethelnContentValidationCommandlet, Log, All);

namespace
{
	bool ParseRequiredValue(const FString& Params, const TCHAR* Name, FString& OutValue, FString& OutFailure)
	{
		const FString Match = FString(Name) + TEXT("=");
		if (!FParse::Value(*Params, *Match, OutValue) || OutValue.TrimStartAndEnd().IsEmpty())
		{
			OutFailure = FString::Printf(TEXT("Missing required commandlet parameter -%s=<value>."), Name);
			return false;
		}
		return true;
	}

	bool IsLowerGitRevision(const FString& Value)
	{
		if (Value.Len() != 40)
		{
			return false;
		}
		for (const TCHAR Character : Value)
		{
			if (!FChar::IsDigit(Character) && (Character < TEXT('a') || Character > TEXT('f')))
			{
				return false;
			}
		}
		return true;
	}

	bool IsLowerFileIdentity(const FString& Value)
	{
		if (Value.Len() != 25 || Value[8] != TEXT(':'))
		{
			return false;
		}
		for (int32 Index = 0; Index < Value.Len(); ++Index)
		{
			if (Index == 8)
			{
				continue;
			}
			const TCHAR Character = Value[Index];
			if (!((Character >= TEXT('0') && Character <= TEXT('9')) || (Character >= TEXT('a') && Character <= TEXT('f'))))
			{
				return false;
			}
		}
		return true;
	}

	bool ParseRequiredPositiveInt64(const FString& Params, const TCHAR* Name, int64& OutValue, FString& OutFailure)
	{
		const FString Match = FString(Name) + TEXT("=");
		if (!FParse::Value(*Params, *Match, OutValue) || OutValue <= 0)
		{
			OutFailure = FString::Printf(TEXT("Missing or invalid required commandlet parameter -%s=<positive integer>."), Name);
			return false;
		}
		return true;
	}

	bool ParseRequiredHandle(const FString& Params, const TCHAR* Name, uint64& OutValue, FString& OutFailure)
	{
		const FString Match = FString(Name) + TEXT("=");
		if (!FParse::Value(*Params, *Match, OutValue) || OutValue == 0)
		{
			OutFailure = FString::Printf(TEXT("Missing or invalid required commandlet parameter -%s=<handle>."), Name);
			return false;
		}
		return true;
	}

	bool IsCanonicalRepositoryRelativePath(const FString& Value)
	{
		return !Value.IsEmpty()
			&& FPaths::IsRelative(Value)
			&& !Value.Contains(TEXT("\\"))
			&& !Value.StartsWith(TEXT("/"))
			&& !Value.Contains(TEXT("../"))
			&& !Value.Contains(TEXT("/../"));
	}

#if PLATFORM_WINDOWS
	bool ReadOpenedFileIdentity(HANDLE Handle, FString& OutIdentity, uint32& OutAttributes, FString& OutFailure)
	{
		BY_HANDLE_FILE_INFORMATION Information{};
		if (!GetFileInformationByHandle(Handle, &Information))
		{
			OutFailure = FString::Printf(TEXT("GetFileInformationByHandle failed for the report output (Win32 %lu)."), GetLastError());
			return false;
		}
		OutAttributes = Information.dwFileAttributes;
		OutIdentity = FString::Printf(TEXT("%08x:%08x%08x"), Information.dwVolumeSerialNumber, Information.nFileIndexHigh, Information.nFileIndexLow);
		return true;
	}

	class FScopedValidatedReportOutput
	{
	public:
		~FScopedValidatedReportOutput()
		{
			Reset();
		}

		bool Adopt(uint64 HandleValue, const FString& ExpectedIdentity, FString& OutFailure)
		{
			Reset();
			Handle = reinterpret_cast<HANDLE>(static_cast<UPTRINT>(HandleValue));
			if (Handle == nullptr || Handle == INVALID_HANDLE_VALUE)
			{
				OutFailure = TEXT("The inherited report output handle is invalid.");
				Handle = INVALID_HANDLE_VALUE;
				return false;
			}

			FString ActualIdentity;
			uint32 Attributes = 0;
			if (!ReadOpenedFileIdentity(Handle, ActualIdentity, Attributes, OutFailure))
			{
				Reset();
				return false;
			}
			if ((Attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 || ActualIdentity != ExpectedIdentity)
			{
				OutFailure = TEXT("The opened report output does not match the wrapper-retained non-reparse identity.");
				Reset();
				return false;
			}
			return true;
		}

		void Reset()
		{
			if (Handle != INVALID_HANDLE_VALUE)
			{
				CloseHandle(Handle);
				Handle = INVALID_HANDLE_VALUE;
			}
		}

	private:
		HANDLE Handle = INVALID_HANDLE_VALUE;
	};

#if WITH_DEV_AUTOMATION_TESTS
	bool ReadPathIdentityForTest(const FString& Path, FString& OutIdentity, FString& OutFailure)
	{
		HANDLE Handle = CreateFileW(*Path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
		if (Handle == INVALID_HANDLE_VALUE)
		{
			OutFailure = TEXT("Could not open the test report path.");
			return false;
		}
		uint32 Attributes = 0;
		const bool bResult = ReadOpenedFileIdentity(Handle, OutIdentity, Attributes, OutFailure);
		CloseHandle(Handle);
		return bResult && (Attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
	}

	uint64 OpenGuardHandleForTest(const FString& Path)
	{
		return reinterpret_cast<UPTRINT>(CreateFileW(
			*Path,
			GENERIC_READ | GENERIC_WRITE | DELETE,
			FILE_SHARE_READ | FILE_SHARE_WRITE,
			nullptr,
			OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
			nullptr));
	}

	bool WriteTextToGuardHandleForTest(uint64 HandleValue, const FString& Text)
	{
		HANDLE Handle = reinterpret_cast<HANDLE>(static_cast<UPTRINT>(HandleValue));
		LARGE_INTEGER Start{};
		if (!SetFilePointerEx(Handle, Start, nullptr, FILE_BEGIN) || !SetEndOfFile(Handle))
		{
			return false;
		}
		FTCHARToUTF8 Utf8(*Text);
		DWORD Written = 0;
		return WriteFile(Handle, Utf8.Get(), static_cast<DWORD>(Utf8.Length()), &Written, nullptr)
			&& Written == static_cast<DWORD>(Utf8.Length())
			&& FlushFileBuffers(Handle);
	}
#endif
#else
	class FScopedValidatedReportOutput
	{
	public:
		bool Adopt(uint64, const FString&, FString& OutFailure)
		{
			OutFailure = TEXT("Retained report output identity validation is supported only on Windows.");
			return false;
		}
	};
#endif
}

UAethelnContentValidationCommandlet::UAethelnContentValidationCommandlet()
{
	IsClient = false;
	IsEditor = true;
	IsServer = false;
	LogToConsole = true;
	ShowErrorCount = true;
	UseCommandletResultAsExitCode = true;
}

int32 UAethelnContentValidationCommandlet::Main(const FString& Params)
{
	FAethelnContentValidationRunArguments Arguments;
	FString ReportFileIdentity;
	uint64 ReportHandleValue = 0;
	FString Failure;
	if (!ParseRequiredValue(Params, TEXT("Report"), Arguments.ReportPath, Failure)
		|| !ParseRequiredValue(Params, TEXT("ReportFileIdentity"), ReportFileIdentity, Failure)
		|| !ParseRequiredHandle(Params, TEXT("ReportHandle"), ReportHandleValue, Failure)
		|| !ParseRequiredValue(Params, TEXT("Policy"), Arguments.PolicyPath, Failure)
		|| !ParseRequiredValue(Params, TEXT("Intake"), Arguments.IntakePath, Failure)
		|| !ParseRequiredValue(Params, TEXT("Revision"), Arguments.Revision, Failure)
		|| !ParseRequiredValue(Params, TEXT("EngineRevision"), Arguments.EngineRevision, Failure)
		|| !ParseRequiredValue(Params, TEXT("EngineTag"), Arguments.EngineTag, Failure)
		|| !ParseRequiredValue(Params, TEXT("EngineBinarySha256"), Arguments.EngineBinarySha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("BuildVersionSha256"), Arguments.BuildVersionSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("Target"), Arguments.Target, Failure)
		|| !ParseRequiredValue(Params, TEXT("Platform"), Arguments.Platform, Failure)
		|| !ParseRequiredValue(Params, TEXT("Configuration"), Arguments.Configuration, Failure)
		|| !ParseRequiredValue(Params, TEXT("EditorBuildCommandSha256"), Arguments.EditorBuildCommandSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("EditorBuildLogSha256"), Arguments.EditorBuildLogSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("CompilerVersion"), Arguments.CompilerVersion, Failure)
		|| !ParseRequiredValue(Params, TEXT("CompilerSha256"), Arguments.CompilerSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("ResourceCompilerVersion"), Arguments.ResourceCompilerVersion, Failure)
		|| !ParseRequiredValue(Params, TEXT("ResourceCompilerSha256"), Arguments.ResourceCompilerSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("TargetReceiptPath"), Arguments.TargetReceipt.Path, Failure)
		|| !ParseRequiredPositiveInt64(Params, TEXT("TargetReceiptSizeBytes"), Arguments.TargetReceipt.SizeBytes, Failure)
		|| !ParseRequiredValue(Params, TEXT("TargetReceiptSha256"), Arguments.TargetReceipt.Sha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("TargetReceiptBuildId"), Arguments.TargetReceipt.BuildId, Failure)
		|| !ParseRequiredValue(Params, TEXT("ModuleManifestPath"), Arguments.ModuleManifest.Path, Failure)
		|| !ParseRequiredPositiveInt64(Params, TEXT("ModuleManifestSizeBytes"), Arguments.ModuleManifest.SizeBytes, Failure)
		|| !ParseRequiredValue(Params, TEXT("ModuleManifestSha256"), Arguments.ModuleManifest.Sha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("ModuleManifestBuildId"), Arguments.ModuleManifest.BuildId, Failure)
		|| !ParseRequiredValue(Params, TEXT("ProjectSha256"), Arguments.ProjectSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("PolicySha256"), Arguments.PolicySha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("IntakeSha256"), Arguments.IntakeSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("InvocationSha256"), Arguments.InvocationSha256, Failure)
		|| !ParseRequiredValue(Params, TEXT("StartedUtc"), Arguments.StartedUtc, Failure)
		|| !ParseRequiredValue(Params, TEXT("RegistrySource"), Arguments.RegistrySource, Failure))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("%s"), *Failure);
		return 3;
	}

	Arguments.bAllowTestRegistrySnapshot = FParse::Param(*Params, TEXT("AllowTestRegistrySnapshot"));
	const bool bHasRegistrySnapshot = FParse::Value(*Params, TEXT("RegistrySnapshot="), Arguments.RegistrySnapshotPath) && !Arguments.RegistrySnapshotPath.IsEmpty();
	const bool bHasRegistrySnapshotSha256 = FParse::Value(*Params, TEXT("RegistrySnapshotSha256="), Arguments.RegistrySnapshotSha256) && !Arguments.RegistrySnapshotSha256.IsEmpty();
	const bool bTestSnapshotSource = Arguments.RegistrySource == TEXT("test_snapshot");
	const bool bAnySnapshotMember = Arguments.bAllowTestRegistrySnapshot || bHasRegistrySnapshot || bHasRegistrySnapshotSha256 || bTestSnapshotSource;
	const bool bAllSnapshotMembers = Arguments.bAllowTestRegistrySnapshot && bHasRegistrySnapshot && bHasRegistrySnapshotSha256 && bTestSnapshotSource;
	if (bAnySnapshotMember != bAllSnapshotMembers)
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("RegistrySnapshot, RegistrySnapshotSha256, AllowTestRegistrySnapshot, and RegistrySource=test_snapshot must be supplied together."));
		return 3;
	}
	if (bHasRegistrySnapshotSha256 && !IsLowerSha256(Arguments.RegistrySnapshotSha256))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("RegistrySnapshotSha256 must be an exact lowercase SHA-256 string."));
		return 3;
	}
	if (Arguments.RegistrySource != TEXT("live_asset_registry") && Arguments.RegistrySource != TEXT("test_snapshot"))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("RegistrySource is unsupported."));
		return 3;
	}
	if (!IsLowerGitRevision(Arguments.Revision)
		|| !IsLowerFileIdentity(ReportFileIdentity)
		|| Arguments.EngineRevision != TEXT("71fe36aac5a8df5ccd66c763ffc902b29b6a9c43")
		|| Arguments.EngineTag != TEXT("5.8.1-release")
		|| Arguments.Target != TEXT("AethelnOnlineEditor")
		|| Arguments.Platform != TEXT("Win64")
		|| Arguments.Configuration != TEXT("Development"))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("Repository, pinned engine, target, platform, or configuration identity is invalid."));
		return 3;
	}
	if (!IsCanonicalRepositoryRelativePath(Arguments.TargetReceipt.Path)
		|| !IsCanonicalRepositoryRelativePath(Arguments.ModuleManifest.Path)
		|| Arguments.TargetReceipt.BuildId != Arguments.ModuleManifest.BuildId)
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("Build artifacts must use canonical repository-relative paths and one non-blank shared build ID."));
		return 3;
	}

	Arguments.ReportPath = FPaths::ConvertRelativePathToFull(Arguments.ReportPath);
	Arguments.PolicyPath = FPaths::ConvertRelativePathToFull(Arguments.PolicyPath);
	Arguments.IntakePath = FPaths::ConvertRelativePathToFull(Arguments.IntakePath);
	if (bAllSnapshotMembers) { Arguments.RegistrySnapshotPath = FPaths::ConvertRelativePathToFull(Arguments.RegistrySnapshotPath); }
	const FString ReportRoot = FPaths::ConvertRelativePathToFull(FPaths::Combine(FPaths::ProjectDir(), TEXT("TestResults")));
	const FString ExpectedPolicyPath = FPaths::ConvertRelativePathToFull(FPaths::Combine(FPaths::ProjectConfigDir(), TEXT("ContentValidation/asset-intake-policy.json")));
	const FString ExpectedIntakePath = FPaths::ConvertRelativePathToFull(FPaths::Combine(FPaths::ProjectConfigDir(), TEXT("ContentValidation/runtime-asset-intake.json")));
	if (!FPaths::IsUnderDirectory(Arguments.ReportPath, ReportRoot)
		|| FPaths::GetCleanFilename(Arguments.ReportPath) != TEXT("content-validation-report.json")
		|| !FPaths::IsSamePath(Arguments.PolicyPath, ExpectedPolicyPath)
		|| !FPaths::IsSamePath(Arguments.IntakePath, ExpectedIntakePath))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("Report, policy, or runtime intake path is outside the supported local contract."));
		return 3;
	}

	for (const FString* Hash : {
		&Arguments.EngineBinarySha256,
		&Arguments.BuildVersionSha256,
		&Arguments.EditorBuildCommandSha256,
		&Arguments.EditorBuildLogSha256,
		&Arguments.CompilerSha256,
		&Arguments.ResourceCompilerSha256,
		&Arguments.TargetReceipt.Sha256,
		&Arguments.ModuleManifest.Sha256,
		&Arguments.ProjectSha256,
		&Arguments.PolicySha256,
		&Arguments.IntakeSha256,
		&Arguments.InvocationSha256 })
	{
		if (!IsLowerSha256(*Hash))
		{
			UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("All provenance hashes must be exact lowercase SHA-256 strings."));
			return 3;
		}
	}

	FScopedValidatedReportOutput ReportOutput;
	if (!ReportOutput.Adopt(ReportHandleValue, ReportFileIdentity, Failure))
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("Report output identity validation failed: %s"), *Failure);
		return 3;
	}
	FPlatformMisc::SetEnvironmentVar(TEXT("AETHELN_CONTENT_VALIDATION_REPORT_HANDLE"), *FString::Printf(TEXT("%llu"), ReportHandleValue));

	const int32 Result = FAethelnContentValidationScanner::Run(Arguments, Failure);
	if (Result != 0)
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Error, TEXT("Content validation failed: %s"), *Failure);
	}
	else
	{
		UE_LOG(LogAethelnContentValidationCommandlet, Display, TEXT("Content validation report written to %s."), *Arguments.ReportPath);
	}
	return Result;
}

#if WITH_DEV_AUTOMATION_TESTS && PLATFORM_WINDOWS

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FAethelnContentValidationReportOutputGuardTest,
	"Aetheln.Content.Validation.ReportOutputGuard",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FAethelnContentValidationReportOutputGuardTest::RunTest(const FString& Parameters)
{
	(void)Parameters;
	const FString Directory = FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("Automation/AethelnContentValidationReportOutputGuard"));
	const FString Path = FPaths::Combine(Directory, TEXT("content-validation-report.json"));
	IFileManager::Get().MakeDirectory(*Directory, true);
	IFileManager::Get().Delete(*Path, false, true, true);
	TestTrue(TEXT("Create disposable report output"), FFileHelper::SaveStringToFile(TEXT("{}"), *Path));

	FString Identity;
	FString Failure;
	TestTrue(TEXT("Read disposable report identity"), ReadPathIdentityForTest(Path, Identity, Failure));
	{
		const uint64 HandleValue = OpenGuardHandleForTest(Path);
		FScopedValidatedReportOutput WrongIdentity;
		TestFalse(TEXT("Reject a mismatched wrapper identity"), WrongIdentity.Adopt(HandleValue, TEXT("00000000:0000000000000000"), Failure));
	}
	{
		const uint64 HandleValue = OpenGuardHandleForTest(Path);
		FScopedValidatedReportOutput Guard;
		TestTrue(TEXT("Retain the exact wrapper identity"), Guard.Adopt(HandleValue, Identity, Failure));
		TestFalse(TEXT("Retained guard blocks pathname deletion or replacement"), IFileManager::Get().Delete(*Path, false, true, true));
		TestTrue(TEXT("Retained inherited handle writes without reopening by pathname"), WriteTextToGuardHandleForTest(HandleValue, TEXT("{\"result\":\"test\"}")));
	}
	TestTrue(TEXT("Disposable report output is removable after guard release"), IFileManager::Get().Delete(*Path, false, true, true));
	IFileManager::Get().DeleteDirectory(*Directory, false, true);
	return true;
}

#endif
