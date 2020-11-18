import { get } from './request.js';
import { formatISODate } from './date.js';
import { dom, clearElement } from './dom.js';


function colorOf(flowType) {
  switch (flowType) {
    case 'Learning':
      return "#ff8822";
    case 'Experimenting':
      return "#0022dd";
    case 'Troubleshooting':
      return "#ee1111";
    case 'Flowing':
      return "#00dd22";
    case 'Rework':
      return "#4500dd";
    case 'Note':
      return "#000000";
    case 'Meeting':
      return "#fff203";
    default:
      return "#ffffff";
  }
}

/**
   Draw a timeline chart in given element with given data
*/
function drawChart(container, selectedDate, flowData, rowLabelling = (_ => selectedDate)) {
  const chart = new google.visualization.Timeline(container);
  const dataTable = new google.visualization.DataTable();

  dataTable.addColumn({ type: 'string', id: 'Role' });
  dataTable.addColumn({ type: 'string', id: 'Flow Type' });
  dataTable.addColumn({ type: 'string', id: 'style', role: 'style' });
  dataTable.addColumn({ type: 'date', id: 'Start' });
  dataTable.addColumn({ type: 'date', id: 'End' });
  flowData.forEach(flow =>
    dataTable.addRow([rowLabelling(flow), flow.flowType, colorOf(flow.flowType), new Date(flow.flowStart), new Date(flow.flowEnd)])
  );
  chart.draw(dataTable);
}

/**
   Draw a timeline containing notes
*/
function drawNotes(container, notesData) {
  const chart = new google.visualization.Timeline(container);
  const dataTable = new google.visualization.DataTable();

  dataTable.addColumn({ type: 'string', id: 'Role' });
  dataTable.addColumn({ type: 'string', id: 'dummy bar label' });
  dataTable.addColumn({ type: 'string', role: 'tooltip' });
  dataTable.addColumn({ type: 'date', id: 'Start' });
  dataTable.addColumn({ type: 'date', id: 'End' });
  notesData.forEach(note => {
    let start = new Date(note.noteStart);
    dataTable.addRow(['Notes', '', note.noteContent, start, new Date(start.getTime() + 60000)]);
  });
  chart.draw(dataTable);
}

/**
   Create a new div container for a timeline
*/
function createTimelineContainer(day, data, notesData) {
  const detailsName = 'checkbox-' + name;
  const notesName = 'checkbox-' + name;
  const chart = <div class="timeline-chart" />;
  const notesDiv = <div class="timeline-chart" />;
  const details = <input type="checkbox" id={detailsName} />;
  const notes = <input type="checkbox" id={notesName} />;

  const container =
    <div id={name} class='timeline'>
      <div class='timeline-controls'>
        <label for={detailsName}>Expand</label>
        {details}
        <label for={notesName}>Notes</label>
        {notes}
      </div>
      {chart}
      {notesDiv}
    </div>;

  details.addEventListener('change', (e) => {
    if (e.target.checked) {
      drawChart(chart, day, data, f => f.flowType);
    } else {
      drawChart(chart, day, data);
    }
  });

  notes.addEventListener('change', (e) => {
    if (e.target.checked) {
      get('/flows/arnaud/' + day + '/notes', (notesData) =>
        drawNotes(notesDiv, notesData));
    } else {
      clearElement(notesDiv);
    }
  });

  document.getElementById('timelines').appendChild(container);
  drawChart(chart, day, data);
}

/**
   Draw several timeline charts within the `timelines` container, each for a different
   data
   For now, we assume the data is a list of days
*/
function drawCharts(flowData) {
  flowData.forEach((f) => {
    const day = formatISODate(new Date(f.groupTime));
    const data = f.subGroup.leafViews;
    createTimelineContainer(day, data);
  });
}

function fetchFlowData(selectedDate) {
  get('/flows/arnaud/' + selectedDate, (flowData) => {
    createTimelineContainer(selectedDate, flowData);
  });
};

function fetchAllFlowData() {
  get('/flows/arnaud?group=Day', drawCharts);
};


export default function timeline() {
  const obj = {};

  obj.fetchFlowData = fetchFlowData;
  obj.fetchAllFlowData = fetchAllFlowData;

  return obj;
}
