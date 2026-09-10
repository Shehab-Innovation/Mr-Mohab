/* ============================================================
   NEXORA — Teacher Content Data (per-tenant curriculum)
   ============================================================
   This file holds the CURRICULUM for one teacher instance
   (grades, units, lessons, PDFs, videos, questions, answers).

   - Exposed as window.NEXORA_CONTENT.gradesData
   - index.html keeps an INLINE FALLBACK copy of this exact data;
     if this file fails to load, the site still works unchanged.
   - Content here must match that fallback byte-for-byte.
   - Presentation, engine, timers, registration: NOT touched.
   ============================================================ */

(function (global) {
    'use strict';

    var gradesData = {

        1: {

            title:'الصف الأول الابتدائي',

            units:[

                {

                    number:1,

                    title:'الأعداد من 1 إلى 10',

                    pdf:'https://drive.google.com/file/d/1yUIxdgJURcG36GXtqkM0UZQm-aTKo0lC/preview',

                    lessons:[

                        {

                            title:'العدد 1',

                            video:'https://www.youtube.com/embed/VIDEO_ID_1',

                            questions:[

                                {

                                    q:'ما هو العدد الذي يأتي بعد 1؟',

                                    options:[
                                        '2',
                                        '3',
                                        '0'
                                    ],

                                    answer:0,

                                    type:'mcq'

                                },

                                {

                                    q:'1 + 1 = ...',

                                    options:[
                                        '1',
                                        '2',
                                        '3'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'العدد 1 هو أصغر عدد موجب',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:0,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: 1 + ... = 2',

                                    type:'fill',

                                    answer:'1'

                                }

                            ]

                        },

                        {

                            title:'العدد 2',

                            video:'https://www.youtube.com/embed/VIDEO_ID_2',

                            questions:[

                                {

                                    q:'العدد الذي يأتي بعد 2 هو ...',

                                    options:[
                                        '1',
                                        '2',
                                        '3'
                                    ],

                                    answer:2,

                                    type:'mcq'

                                },

                                {

                                    q:'2 + 2 = ...',

                                    options:[
                                        '3',
                                        '4',
                                        '5'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'العدد 2 أكبر من العدد 1',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:0,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: 2 + 1 = ...',

                                    type:'fill',

                                    answer:'3'

                                }

                            ]

                        },

                        {

                            title:'العدد 3',

                            video:'https://www.youtube.com/embed/VIDEO_ID_3',

                            questions:[

                                {

                                    q:'3 + 1 = ...',

                                    options:[
                                        '3',
                                        '4',
                                        '5'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'العدد 3 يأتي بعد العدد 2',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:0,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: 3 + 2 = ...',

                                    type:'fill',

                                    answer:'5'

                                }

                            ]

                        }

                    ],

                    unitQuestions:[

                        {

                            q:'ما هو العدد الذي يأتي بعد 3؟',

                            options:[
                                '2',
                                '4',
                                '5'
                            ],

                            answer:1,

                            type:'mcq'

                        },

                        {

                            q:'كم عدد الأصابع في يد واحدة؟',

                            options:[
                                '3',
                                '4',
                                '5'
                            ],

                            answer:2,

                            type:'mcq'

                        },

                        {

                            q:'أكمل: 1, 2, 3, ..., 5',

                            type:'fill',

                            answer:'4'

                        },

                        {

                            q:'أكمل: 2 + 3 = ...',

                            type:'fill',

                            answer:'5'

                        },

                        {

                            q:'أكمل: 4 - 1 = ...',

                            type:'fill',

                            answer:'3'

                        },

                        {

                            q:'أكمل: 3 + 2 = ...',

                            type:'fill',

                            answer:'5'

                        }

                    ]

                },

                {

                    number:2,

                    title:'الجمع والطرح',

                    pdf:'https://drive.google.com/file/d/1yUIxdgJURcG36GXtqkM0UZQm-aTKo0lC/preview',

                    lessons:[

                        {

                            title:'الجمع',

                            video:'https://www.youtube.com/embed/VIDEO_ID_4',

                            questions:[

                                {

                                    q:'2 + 3 = ...',

                                    options:[
                                        '4',
                                        '5',
                                        '6'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'5 + 5 = 10',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:0,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: 3 + 4 = ...',

                                    type:'fill',

                                    answer:'7'

                                }

                            ]

                        },

                        {

                            title:'الطرح',

                            video:'https://www.youtube.com/embed/VIDEO_ID_5',

                            questions:[

                                {

                                    q:'5 - 2 = ...',

                                    options:[
                                        '2',
                                        '3',
                                        '4'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'3 - 1 = 1',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:1,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: 8 - 3 = ...',

                                    type:'fill',

                                    answer:'5'

                                }

                            ]

                        }

                    ],

                    unitQuestions:[

                        {

                            q:'2 + 4 = ...',

                            options:[
                                '5',
                                '6',
                                '7'
                            ],

                            answer:1,

                            type:'mcq'

                        },

                        {

                            q:'7 - 2 = 5',

                            options:[
                                'صح',
                                'خطأ'
                            ],

                            answer:0,

                            type:'truefalse'

                        },

                        {

                            q:'أكمل: 6 + 2 = ...',

                            type:'fill',

                            answer:'8'

                        },

                        {

                            q:'أكمل: 9 - 4 = ...',

                            type:'fill',

                            answer:'5'

                        },

                        {

                            q:'أكمل: 10 - 3 = ...',

                            type:'fill',

                            answer:'7'

                        }

                    ]

                },

                {

                    number:3,

                    title:'الأشكال الهندسية',

                    pdf:'https://drive.google.com/file/d/1yUIxdgJURcG36GXtqkM0UZQm-aTKo0lC/preview',

                    lessons:[

                        {

                            title:'المربع',

                            video:'https://www.youtube.com/embed/VIDEO_ID_6',

                            questions:[

                                {

                                    q:'كم عدد أضلاع المربع؟',

                                    options:[
                                        '3',
                                        '4',
                                        '5'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'أكمل: المربع له ... أضلاع متساوية',

                                    type:'fill',

                                    answer:'4'

                                }

                            ]

                        },

                        {

                            title:'المثلث',

                            video:'https://www.youtube.com/embed/VIDEO_ID_7',

                            questions:[

                                {

                                    q:'الشكل الذي له 3 أضلاع هو ...',

                                    options:[
                                        'المربع',
                                        'المثلث',
                                        'الدائرة'
                                    ],

                                    answer:1,

                                    type:'mcq'

                                },

                                {

                                    q:'أكمل: المثلث له ... أضلاع',

                                    type:'fill',

                                    answer:'3'

                                }

                            ]

                        },

                        {

                            title:'الدائرة',

                            video:'https://www.youtube.com/embed/VIDEO_ID_8',

                            questions:[

                                {

                                    q:'الدائرة ليس لها أضلاع',

                                    options:[
                                        'صح',
                                        'خطأ'
                                    ],

                                    answer:0,

                                    type:'truefalse'

                                },

                                {

                                    q:'أكمل: الدائرة لها ... أضلاع',

                                    type:'fill',

                                    answer:'0'

                                }

                            ]

                        }

                    ],

                    unitQuestions:[

                        {

                            q:'المربع له ... زوايا',

                            options:[
                                '3',
                                '4',
                                '5'
                            ],

                            answer:1,

                            type:'mcq'

                        },

                        {

                            q:'المثلث له 4 أضلاع',

                            options:[
                                'صح',
                                'خطأ'
                            ],

                            answer:1,

                            type:'truefalse'

                        },

                        {

                            q:'أكمل: المربع له ... أضلاع متساوية',

                            type:'fill',

                            answer:'4'

                        },

                        {

                            q:'أكمل: المثلث له ... أضلاع',

                            type:'fill',

                            answer:'3'

                        }

                    ]

                }

            ]

        },

        2:{
            title:'الصف الثاني الابتدائي',
            units:[]
        },

        3:{
            title:'الصف الثالث الابتدائي',
            units:[]
        },

        4:{
            title:'الصف الرابع الابتدائي',
            units:[]
        },

        5:{
            title:'الصف الخامس الابتدائي',
            units:[]
        },

        6:{
            title:'الصف السادس الابتدائي',
            units:[]
        }

    };


    global.NEXORA_CONTENT = {
        gradesData: gradesData
    };

})(window);
