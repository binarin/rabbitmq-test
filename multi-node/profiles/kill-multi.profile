
{resource,  ["resources/rabbit.resource"]}.
{targets,  [multi_node_deaths_SUITE]}.
{aggressive_teardown, {minutes, 12}}.
{setup_timetrap,      {minutes, 5}}.     
{teardown_timetrap,   {minutes, 10}}.
{execution_timetrap,  {hours, 1}}.
