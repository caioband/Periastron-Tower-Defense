local EnemyWeatherChange = {}

EnemyWeatherChange.Enemies = { "OverseerMage" }
EnemyWeatherChange.GraceTime = 5 --delay before it ddoes the ability
EnemyWeatherChange.EnemyAnim = "Change"
EnemyWeatherChange.ApplyDelay = 1 
EnemyWeatherChange.StopWhileCasting = false
EnemyWeatherChange.CastTime = 2
EnemyWeatherChange.Pool = "Map" -- "Map" or "All"
EnemyWeatherChange.FallbackToAll = true
EnemyWeatherChange.Exclude = {}

return EnemyWeatherChange