local EnemyWeatherChange = {}

EnemyWeatherChange.Enemies = { "OverseerMage" }
EnemyWeatherChange.GraceTime = 5
EnemyWeatherChange.EnemyAnim = "Change"
EnemyWeatherChange.VFX = "WeatherChangeVFX"
EnemyWeatherChange.CastTime = 2 -- how long the cast lasts: the VFX stays this long (and the mage stops if StopWhileCasting)
EnemyWeatherChange.ApplyDelay = 1
EnemyWeatherChange.StopWhileCasting = false
EnemyWeatherChange.Pool = "Map" -- "Map" or "All"
EnemyWeatherChange.FallbackToAll = true
EnemyWeatherChange.Exclude = {}

return EnemyWeatherChange