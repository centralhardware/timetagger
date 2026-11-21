package timetagger

import io.ktor.server.application.Application
import io.ktor.server.plugins.di.dependencies
import timetagger.auth.AccessTokens
import timetagger.auth.AuthService
import timetagger.auth.PasswordService
import timetagger.config.Config
import timetagger.db.ApiKeyRepository
import timetagger.db.Database
import timetagger.db.RecordRepository
import timetagger.db.RefreshTokenRepository
import timetagger.db.SettingRepository
import timetagger.db.UserRepository
import timetagger.db.WorkspaceRepository
import timetagger.service.MergeService
import timetagger.service.MergeSettings
import timetagger.service.RecordService
import timetagger.service.SettingService
import timetagger.service.SyncService
import timetagger.service.WorkspaceService

/**
 * Registers every component with Ktor's DI container; routes and plugins resolve what they need,
 * and each class gets its own dependencies by constructor type.
 * [config] and [db] are owned by the caller (main or a test), so the container never closes them.
 */
fun Application.registerDependencies(config: Config, db: Database) {
    dependencies {
        provide { config }
        provide { db }.cleanup { }

        provide<UserRepository>(::UserRepository)
        provide<RecordRepository>(::RecordRepository)
        provide<SettingRepository>(::SettingRepository)
        provide<WorkspaceRepository>(::WorkspaceRepository)
        provide<RefreshTokenRepository>(::RefreshTokenRepository)
        provide<ApiKeyRepository>(::ApiKeyRepository)

        // Plain values read from the config; everything below is built by constructor injection.
        provide { AccessTokens(resolve<Config>().jwtKey) }
        provide { MergeSettings.from(resolve<Config>()) }

        provide<PasswordService>(::PasswordService)
        provide<AuthService>(::AuthService)
        provide<RecordService>(::RecordService)
        provide<WorkspaceService>(::WorkspaceService)
        provide<SettingService>(::SettingService)
        provide<SyncService>(::SyncService)
        provide<MergeService>(::MergeService)
    }
}
