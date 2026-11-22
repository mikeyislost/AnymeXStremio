# User application sources and include directories (LG's template), plus:
# the runner talks to the app over LG's C messenger API, which lives in
# libflutter_common.so. LG's build only links the embedder into the runner,
# so link the common library too. link_libraries() applies to targets made
# after this file is included, i.e. the runner itself.

set(USER_APP_EXTRA_SRCS
  runner/main.cc
)

set(USER_APP_EXTRA_INCLUDE_DIRS
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${CMAKE_CURRENT_SOURCE_DIR}/runner
)

link_libraries("${FLUTTER_COMMON_LIBRARY}")
