open! Base

type violation = { limit : int; actual : int }

let error ~limit ~actual =
  Base.Error.createf "request body too large (max %d bytes, got %d bytes)" limit
    actual

let enforce ~limit ~actual =
  if actual > limit then Error (error ~limit ~actual) else Ok ()
