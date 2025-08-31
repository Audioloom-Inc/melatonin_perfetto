#include "melatonin_perfetto.h"

#if PERFETTO

    #include "../perfetto/sdk/perfetto.cc"

    PERFETTO_TRACK_EVENT_STATIC_STORAGE();

#endif
