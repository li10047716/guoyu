# 0.7.34：品牌统一为「果屿」，两个构建变体只差站源授权范围，
# 不再用两个显示名。exe 名与 windows/CMakeLists.txt 的 BINARY_NAME 保持一致，
# 发布时由 scripts/package_release.py 按变体 slug 重命名。
set(APP_DISPLAY_NAME "果屿")
set(APP_EXECUTABLE_NAME "guoyu.exe")
foreach(ENTRY IN LISTS FLUTTER_TOOL_ENVIRONMENT)
  if(ENTRY MATCHES "^DART_DEFINES=(.*)$")
    string(REPLACE "," ";" APP_DART_DEFINES "${CMAKE_MATCH_1}")
    foreach(DEFINE IN LISTS APP_DART_DEFINES)
      if(DEFINE STREQUAL "QUxMX1NPVVJDRVM9dHJ1ZQ==")
        set(APP_DISPLAY_NAME "果屿")
        set(APP_EXECUTABLE_NAME "guoyu.exe")
      elseif(DEFINE STREQUAL "QUxMX1NPVVJDRVM9ZmFsc2U=")
        set(APP_DISPLAY_NAME "果屿")
        set(APP_EXECUTABLE_NAME "guoyu.exe")
      endif()
    endforeach()
  endif()
endforeach()
