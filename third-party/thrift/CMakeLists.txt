include(ExternalProject)
include(HPHPFunctions)

get_target_property(BOOST_INCLUDE_DIR boost INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(BOOST_LIBRARIES boost INTERFACE_LINK_LIBRARIES)
list(GET BOOST_LIBRARIES 0 FIRST_LIB)
if("${FIRST_LIB}" MATCHES ".+/${CMAKE_STATIC_LIBRARY_PREFIX}boost_.+${CMAKE_STATIC_LIBRARY_SUFFIX}$")
  set(Boost_USE_STATIC_LIBS ON)
else()
  set(Boost_USE_STATIC_LIBS OFF)
endif()
get_filename_component(BOOST_LIBRARY_DIR "${FIRST_LIB}" DIRECTORY)
get_target_property(ZSTD_INCLUDE_DIR zstd INTERFACE_INCLUDE_DIRECTORIES)
get_target_property(ZSTD_LIBRARY zstd INTERFACE_LINK_LIBRARIES)
get_target_property(JEMALLOC_INCLUDE_DIR jemalloc INTERFACE_INCLUDE_DIRECTORIES)

find_package(FLEX REQUIRED)
# Thrift uses `%code`, which isn't in 2.x
find_package(BISON 3.0 REQUIRED)

SET_HHVM_THIRD_PARTY_SOURCE_ARGS(
  THRIFT_SOURCE_ARGS
  SOURCE_URL
  "https://github.com/facebook/fbthrift/archive/refs/tags/v2021.10.18.00.tar.gz"
  SOURCE_HASH
  "SHA256=53570cf529f7574628677b46e0e4f49ffac93cd117ae5611f399230cdcec82ca"
  FILENAME_PREFIX
  "fbthrift-"
)

ExternalProject_Add(
  bundled_thrift
  ${THRIFT_SOURCE_ARGS}
  PATCH_COMMAND
    "${CMAKE_COMMAND}" -E copy
    "${CMAKE_SOURCE_DIR}/CMake/FindGlog.cmake"
    <SOURCE_DIR>/thrift/cmake/FindGlog.cmake
    &&
    "${CMAKE_CURRENT_SOURCE_DIR}/../apply-quilt-patches.sh"
    "${CMAKE_CURRENT_SOURCE_DIR}/patches"
  CMAKE_ARGS
    "-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH}"
    -DCMAKE_MODULE_PATH=${CMAKE_SOURCE_DIR}/CMake
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>

    -DFLEX_EXECUTABLE=${FLEX_EXECUTABLE}
    -DBISON_EXECUTABLE=${BISON_EXECUTABLE}
    
    -DWITHOUT_GFLAGS=ON

    -DOPENSSL_INCLUDE_DIR=${OPENSSL_INCLUDE_DIR}
    -DOPENSSL_CRYPTO_LIBRARY=${OPENSSL_CRYPTO_LIBRARY}
    -DBoost_NO_SYSTEM_PATHS=ON
    -DBoost_NO_BOOST_CMAKE=ON
    -DBoost_USE_STATIC_LIBS=${Boost_USE_STATIC_LIBS}
    -DBoost_INCLUDE_DIR=${BOOST_INCLUDE_DIR}
    "-DBOOST_LIBRARYDIR=${BOOST_LIBRARY_DIR}"
    "-DLIBGLOG_INCLUDE_DIR=${LIBGLOG_INCLUDE_DIR}"
    "-DLIBGLOG_LIBRARY=${LIBGLOG_LIBRARY}"
    "-DZSTD_INCLUDE_DIRS=${ZSTD_INCLUDE_DIR}"
    "-DZSTD_LIBRARIES=${ZSTD_LIBRARY}"

    "-Dfizz_DIR=${FIZZ_INSTALL_DIR}/lib/cmake/fizz"
    "-Dfmt_DIR=${FMT_INSTALL_DIR}/lib/cmake/fmt"
    "-Dfolly_DIR=${FOLLY_INSTALL_DIR}/lib/cmake/folly"
    "-Dwangle_DIR=${WANGLE_INSTALL_DIR}/lib/cmake/wangle"

    "-DCMAKE_CXX_FLAGS=-I${JEMALLOC_INCLUDE_DIR}"
)
ExternalProject_Get_property(bundled_thrift INSTALL_DIR)

set(
  THRIFT_DEPS
  fizz
  fmt
  folly
  proxygen
  wangle
  zstd
)
add_dependencies(bundled_thrift ${THRIFT_DEPS})
add_library(thrift INTERFACE)
add_dependencies(thrift bundled_thrift)
target_include_directories(thrift INTERFACE "${INSTALL_DIR}/include")
target_link_libraries(thrift INTERFACE ${THRIFT_DEPS} ${OPENSSL_LIBRARIES})
set(THRIFT_INSTALL_DIR "${INSTALL_DIR}" PARENT_SCOPE)

# ----- Export a single 'thrift' library target -----

# Usage: thrift_lib NAME [DEP1 [DEP2...]]
macro(thrift_lib NAME)
  set(DEPENDENCIES)
  foreach(DEP ${ARGN})
    list(APPEND DEPENDENCIES "thrift_lib_${DEP}")
  endforeach()
  add_library("thrift_lib_${NAME}" STATIC IMPORTED)
  set_target_properties(
    "thrift_lib_${NAME}"
    PROPERTIES
    IMPORTED_LOCATION
    "${INSTALL_DIR}/lib/${CMAKE_STATIC_LIBRARY_PREFIX}${NAME}${CMAKE_STATIC_LIBRARY_SUFFIX}"
  )

  if(DEPENDENCIES)
    # On newer versions of CMake, we can use `target_link_libraries()`, but this isn't supported
    # on `IMPORTED` targets in the oldest versions we currently support.
    set_target_properties(
      "thrift_lib_${NAME}"
      PROPERTIES
      INTERFACE_LINK_LIBRARIES
      "${DEPENDENCIES}"
    )
  endif()

  target_link_libraries(thrift INTERFACE "thrift_lib_${NAME}")
endmacro()

thrift_lib(concurrency)
thrift_lib(rpcmetadata)
thrift_lib(thrift-core)
thrift_lib(thriftmetadata)

thrift_lib(transport concurrency thrift-core rpcmetadata)
thrift_lib(async concurrency transport)
thrift_lib(thriftprotocol thrift-core)
thrift_lib(thriftfrozen2 thriftmetadata thriftprotocol)
thrift_lib(thriftcpp2 rpcmetadata thriftmetadata thriftfrozen2 thriftprotocol transport async)

# ----- Export the thrift compiler as a target -----

add_executable(thrift1 IMPORTED GLOBAL)
add_dependencies(thrift1 INTERFACE bundled_thrift)
set_target_properties(
  thrift1
  PROPERTIES
  IMPORTED_LOCATION "${INSTALL_DIR}/bin/thrift1${CMAKE_EXECUTABLE_SUFFIX}"
)
